#!/usr/bin/env bash
# Checks that closing a tab can't freeze Anser: a tab's helper must exit
# promptly when its terminal hangs up, even with output nobody will read.
# (login(1) waits for unread output to drain as it exits; the helper drops it.)
#
#   scripts/test-session-helper.sh [path/to/anser-session]
#
# Prints PASS or FAIL lines like the self-test; exits 1 on a failure.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
helper="${1:-$root/build/Anser.app/Contents/MacOS/anser-session}"
[[ -x "$helper" ]] || { echo "FAIL  session helper: $helper not found (build it first)"; exit 1; }
# Unix socket paths are short (104 bytes), so not the scratch folders.
dir="$(mktemp -d "${TMPDIR:-/tmp}/anser-sh.XXXXXX")"
chmod 700 "$dir"
cleanup() {
    pkill -f "anser-selftest-flood" 2>/dev/null
    for p in $(pgrep -f "anser-session daemon"); do lsof -p "$p" 2>/dev/null | grep -q "$dir" && kill "$p"; done
    rm -rf "$dir"
}
trap cleanup EXIT

python3 -I - "$dir/d.sock" "$helper" <<'EOF'
import os, pty, time, signal, sys, uuid
sock, helper = sys.argv[1], sys.argv[2]
failed = False
for run in range(4):
    env = dict(os.environ, ANSER_SESSION_ID=str(uuid.uuid4()).upper(), ANSER_SESSION_SOCKET=sock,
               ANSER_SESSION_COMMAND="yes anser-selftest-flood", TERM="xterm-256color")
    # The way Ghostty starts a tab's command on macOS.
    argv = ["/usr/bin/login", "-flp", os.environ["USER"], "/bin/bash", "--noprofile", "--norc", "-c", f"exec -l '{helper}' attach"]
    pid, master = pty.fork()
    if pid == 0:
        os.execve(argv[0], argv, env)
    start = time.time()
    while time.time() - start < 1.0:      # a live tab, reading
        try: os.read(master, 65536)
        except OSError: break
    time.sleep(0.3)                        # the tab is closing: nobody reads any more
    group = os.getpgid(pid)
    through_helper = "attach" in os.popen(f"ps -o command= -g {group}").read()
    if run % 2:
        # Anser ends the shell first (the daemon tells the helper it exited), then hangs up.
        os.system("pkill -f anser-selftest-flood")
        time.sleep(0.3)
        # The terminal still sends a few bytes while it closes (keys, reports).
        try: os.write(master, b"q\r")
        except OSError: pass
        time.sleep(0.2)
    os.killpg(group, signal.SIGHUP)
    t = time.time()
    closed = False
    while time.time() - t < 3:
        if os.waitpid(pid, os.WNOHANG)[0]: closed = True; break
        time.sleep(0.02)
    os.close(master)
    if not closed: os.waitpid(pid, 0)
    if not through_helper:
        print("FAIL  closing a busy tab: the helper didn't start (ran the command directly)"); failed = True; break
    if not closed:
        print("FAIL  closing a busy tab doesn't wait for its unread output (stuck; Anser would freeze)"); failed = True; break
else:
    print("PASS  closing a busy tab doesn't wait for its unread output")
sys.exit(1 if failed else 0)
EOF
