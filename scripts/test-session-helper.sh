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
status=$?

# A tab that reads the shell's terminal itself ("direct"): the helper hands the terminal
# over after the replay, takes the tab's history back when it leaves, reads the terminal
# again for the next tab, and still reports the shell's exit.
python3 -I - "$dir/direct.sock" "$helper" <<'EOF'
import json, os, select, socket, struct, subprocess, sys, time, uuid
sock_path, helper = sys.argv[1], sys.argv[2]
daemon = subprocess.Popen([helper, "daemon"], env=dict(os.environ, ANSER_SESSION_SOCKET=sock_path),
                          stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(100):
    if os.path.exists(sock_path): break
    time.sleep(0.05)
sid = str(uuid.uuid4()).upper()
script = "printf 'ready\\n'; while IFS= read -r l; do printf 'got:%s\\n' \"$l\"; done # anser-selftest-direct"
results = []
def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS  " if ok else "FAIL  ") + "direct tab: " + name + ("" if ok or not detail else "  — " + detail))

def frame(kind, payload=b""): return kind + struct.pack(">I", len(payload)) + payload
def hello(direct):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(sock_path)
    h = {"v": 1, "mode": "attach", "id": sid, "create": True, "cols": 80, "rows": 24, "cwd": "/tmp",
         "env": {"PATH": "/usr/bin:/bin", "TERM": "xterm-256color"}, "command": "/bin/sh -c '" + script.replace("'", "'\\''") + "'",
         "direct": direct}
    s.sendall(frame(b"H", json.dumps(h).encode()))
    return s
class Frames:
    def __init__(self, s): self.s, self.buf, self.fds = s, b"", []
    def next(self, timeout=3):
        end = time.time() + timeout
        while True:
            if len(self.buf) >= 5:
                n = struct.unpack(">I", self.buf[1:5])[0]
                if len(self.buf) >= 5 + n:
                    k, p = self.buf[:1], self.buf[5:5 + n]; self.buf = self.buf[5 + n:]; return k, p
            left = end - time.time()
            if left <= 0 or not select.select([self.s], [], [], left)[0]: return None, b""
            data, fds, _, _ = socket.recv_fds(self.s, 65536, 4)
            if not data: return None, b""
            self.buf += data; self.fds += fds
def read_until(fd, text, timeout=3):
    got, end = b"", time.time() + timeout
    while text not in got and time.time() < end:
        if select.select([fd], [], [], 0.1)[0]:
            try: got += os.read(fd, 65536)
            except BlockingIOError: pass
            except OSError: break
    return got

try:
    # 1. Direct: replay-less first attach, then the terminal itself.
    s = hello(True); f = Frames(s)
    k, _ = f.next()
    check("helper hands over the terminal", k == b"D" and len(f.fds) == 1, repr(k))
    if f.fds:
        t = f.fds[0]
        check("shell output arrives on it", b"ready" in read_until(t, b"ready"))
        os.write(t, b"hello\n")
        check("typing reaches the shell", b"got:hello" in read_until(t, b"got:hello"))
        os.write(t, b"quiet\n"); read_until(t, b"got:quiet")
        # Leaving: hand the history back, close everything.
        s.sendall(frame(b"P", b"history-from-tab\r\n"))
        time.sleep(0.2); os.close(t); s.close(); time.sleep(0.3)

        # 2. A relay tab next: the history comes back, and the helper reads the terminal again.
        s = hello(False); f = Frames(s)
        shown = b""
        for _ in range(5):
            k, p = f.next(1)
            if k is None: break
            if k == b"O": shown += p
        check("history handed back is replayed", shown.startswith(b"history-from-tab"), repr(shown[:80]))
        s.sendall(frame(b"I", b"again\n"))
        shown = b""
        end = time.time() + 3
        while b"got:again" not in shown and time.time() < end:
            k, p = f.next(1)
            if k == b"O": shown += p
        check("helper reads the terminal again after the tab left", b"got:again" in shown, repr(shown[-80:]))
        s.close(); time.sleep(0.3)

        # 3. Direct again; the shell ends (end of input): the exit comes promptly.
        s = hello(True); f = Frames(s)
        k = None
        for _ in range(5):
            k, _ = f.next(1)
            if k in (b"D", None): break
        if f.fds:
            t = f.fds[-1]
            start = time.time()
            os.write(t, b"\x04")
            # Keep reading, like Ghostty: a shell can't finish exiting while its
            # terminal holds output nobody has read (the echoed ^D).
            k = None
            while k is None and time.time() - start < 3:
                read_until(t, b"\0", 0.05)
                k, p = f.next(0.05)
            took = time.time() - start
            check("shell's exit is reported", k == b"X" and took < 1.0, f"{k!r} after {took:.2f}s")
            os.close(t)
        else:
            check("helper hands over the terminal again", False, repr(k))
        s.close()
finally:
    daemon.terminate()
sys.exit(0 if all(results) else 1)
EOF
[[ $? -eq 0 && $status -eq 0 ]]
