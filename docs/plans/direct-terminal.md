# Plan: Ghostty reads kept shells directly

**Goal:** with "Keep shells running" on (the default), output streams at the speed of a plain tab, within 1.3×. Today a 50 MB `cat` takes 0.72–0.93 s, against 0.36–0.46 s for a plain tab.

**Why it's slow today:** the shell's terminal belongs to the `anser-session` daemon. Each tab's Ghostty runs `anser-session attach` in a second terminal and copies everything across, so there are two terminals in a row. Measurements show the copy into the second terminal is the limit. Handing the shell's terminal to `attach` didn't help (see the side-session notes).

**The change:** the daemon hands the shell's terminal straight to Ghostty. There's no `attach` process and no second terminal. The daemon still holds the terminal open, so the shell survives Anser quitting, updating or crashing.

```
today:   shell ─pty─ daemon ─socket─ attach ─pty─ Ghostty
after:   shell ─pty───────────────────────────── Ghostty
                 └ daemon keeps it open; Anser keeps a socket to the daemon per tab
```

## Phase 1: Ghostty patch (`patches/ghostty-pty-adopt.patch`), about 1.5 days. Done (27 Nov), not released

Named so it sorts after `ghostty-anser` and `ghostty-close-freeze`, which it builds on. The API is `adopt_pty` / `pty_fd` / `initial_output(_len)` in `ghostty_surface_config_s` (the fd is duplicated, so the caller keeps its own), `ghostty_surface_child_exited(surface, code, runtime_ms)`, `ghostty_surface_recent_output(surface, buf, cap)` and `ghostty_surface_recent_output_total(surface)`. `TerminalSurfaceView` takes `adoptPTY:` and `initialOutput:`. The test is `ANSER_SELFTEST_ONLY=adopt`.

All changes are in `src/termio/Exec.zig`, `src/apprt/embedded.zig` and `include/ghostty.h`. The current files are Ghostty main 6d2442 with Zig 0.17.1.

1. **Adopt an existing terminal.** New fields at the end of `ghostty_surface_config_s`: `bool adopt_pty; int pty_fd; const uint8_t *initial_output; size_t initial_output_len`. They go at the end so existing callers zero them.
   - `Subprocess.start` skips `Pty.open` and spawning, and returns `{read: fd, write: fd}`.
   - A new `.adopted` process kind with no pid means there's no `xev.Process` watcher (as with flatpak).
   - `resize` keeps working through `TIOCSWINSZ` on the fd. The Pty wrapper has no slave, so `deinit` must not close a slave fd.
2. **Never kill an adopted shell.** For `.adopted`, `Subprocess.stop` only closes Ghostty's copy of the fd, with no `killpg` and no `waitpid`. Today `killPid` loops until the child exits, which would hang on a shell Ghostty doesn't own.
3. **Restored output goes in before reading starts.** `threadEnter` passes `initial_output` to `processOutput` before it spawns the read thread. This avoids injecting output from the app thread later.
4. **Exit comes from Anser.** New `ghostty_surface_child_exited(surface, code)` pushes the same `child_exited` message the process watcher would. Ghostty's close and "process exited" behaviour then stays as it is.
5. **A copy of recent output, for the replay.** After each parsed batch in the read thread's parse stage, append it to a 2 MB ring kept per surface. New `ghostty_surface_recent_output(surface, &ptr, &len)` returns a copy, starting after a line break.
   - It costs one memcpy per 64 KB batch, which is negligible next to parsing.

**Done when:** Ghostty builds, and a tiny test in the Anser self-test can open a pty itself, adopt it, show output, resize, and close without killing the process.

## Phase 2: daemon hands the terminal over, about 0.5 day. Done (27 Nov), not released

Reuse the daemon half of `relay-handoff-experiment.patch`:
- the hello gets `"direct": true`;
- after the replay, the daemon sends the master fd with a `D` frame (`SCM_RIGHTS`) and stops reading the terminal while that client owns it;
- a `P` frame replaces its replay;
- `SIGCHLD` wakes it so exits are noticed without reading the terminal.

The `attach` half of the experiment is not needed.

What landed:
- `DescriptorPassing` in AnserCore (send and receive a descriptor; Anser will use the receiving side in phase 3).
- `D` (handoff) and `P` (replay) frames.
- The daemon hands the terminal over when the hello says `"direct": true`, stops reading it while that client owns it, swaps in a `P` replay, and wakes on `SIGCHLD`.
- Tests: `DescriptorPassingTests`, and a direct-tab section in `scripts/test-session-helper.sh` (handoff, output, typing, history handed back and replayed, the daemon reading again after the tab leaves, exit reported).

Notes for phase 3:
- The shared `O_NONBLOCK` flag is fine: the daemon already keeps its master non-blocking.
- A shell can't finish exiting while its terminal holds output nobody has read. Ghostty reads continuously, so this is fine, but anything that stops reading (a stuck surface) keeps the shell half-exited until it reads again or the tab lets go.
- On `E` ("open in another window"), the old tab must close its surface promptly. Until it does, two Ghosttys read the same terminal.

**Done when:** a unit test passes a pty fd over a socketpair and reads through it, and `scripts/test-session-helper.sh` still passes.

## Phase 3: Anser opens kept tabs directly, about 1 day. Done (27 Nov), not released

1. **New `SessionClient`, one per kept tab.** In `PaneView.init`, before the surface exists:
   - connect to the daemon, starting it if needed;
   - send the hello with size, cwd, env and command;
   - collect the replay frames, then the fd. Time out after 1 s.
   - Create the surface with `adopt_pty` and `initial_output` = the replay. Today's alternate-screen redraw nudge stays in the daemon.
2. **Keep the socket open** on a background `DispatchSource`:
   - an `X` frame calls `ghostty_surface_child_exited`;
   - an `E` frame ("open in another window") shows the message and closes the tab.
3. **Fallback stays.** If the daemon doesn't hand the terminal over (for example an older daemon still running from before an update, or anything that times out), close that socket and start the tab exactly as today, with the `attach` command. The shell is already running under that id, so it reattaches.
4. **Busy check.** `PaneView+Panels.swift:94` asks the daemon because Ghostty's foreground process used to be `attach`. With the real terminal, `tcgetpgrp` on it works directly. Keep the daemon question as a fallback.

What landed:
- `DirectTerminal` (Sources/Anser/Session): connects (starting the helper if needed), sends the hello with `"direct": true` and the environment Ghostty would give the shell, collects the replay and the terminal (1 s timeout), then watches the socket. `X` → `ghostty_surface_child_exited`; `E` → the tab closes without ending the shell; if the helper goes away, the shell's exit is watched directly (kqueue).
- `PaneView` tries it first and falls back to `attach`. `ANSER_DIRECT_TABS=0` turns it off (for comparisons and the fallback test).
- The `D` frame now carries `{"pid": shell}`; the busy check uses `tcgetpgrp` on the terminal against it.
- Closing a tab that keeps its shell already hands the tab's recent output back as a `P` frame (the first half of phase 4), so reattaching shows the history.
- Tests: `ANSER_SELFTEST_ONLY=direct` (13 checks: handoff, environment, busy, keep and reattach with history, open elsewhere, exit, attach fallback). `adopt`, `busytabs`, `test-session-helper.sh` and `swift test` still pass.
- Rough speed (perf subset, 50 MB `cat`, 3 runs each): direct 0.36–0.67 s (median 0.41), plain 0.26–0.46 s (median 0.36), relay 0.90 s. That's about 1.1× plain; phase 5 makes it a paired check.

Notes:
- The environment is rebuilt in Swift from Ghostty's rules (TERM, TERMINFO, GHOSTTY_*, PATH, XDG_DATA_DIRS, MANPATH, TERM_PROGRAM_VERSION, PWD). `env = …` lines in the user's own Ghostty config aren't copied into direct shells yet.
- On the relay path, a tab closed by `E` goes through the normal close, which asks the helper to end the shell that just moved to the other window. The direct path sets `keepShellOnClose` first. Worth fixing for the fallback too.

## Phase 4: history survives quits, updates and crashes, about 0.5 day. Done (27 Nov), not released

What landed:
- **Quit and update:** neither closes the panes (Sparkle restarts through the same `NSApp.terminate`), so `teardown` never ran and the hand-back didn't happen. `applicationWillTerminate` now hands each direct tab's history back when shells are kept.
- **Crash:** every 5 s, `DirectTerminal.snapshotAll` sends a `P` for tabs whose `ghostty_surface_recent_output_total` changed. The copy is taken on the main thread, where the surface lives (about 2 MB at most, only when output changed); the send happens on the terminal's queue.
- All socket writes now go through that queue and stop once the socket closes. Before, a hand-back after the helper had gone away could write to a closed descriptor.
- Test: the `direct` subset checks that a snapshot reaches the helper, then lets go of a tab without the hand-back (as a crash would) and checks that the reopened tab shows the snapshot's history. Now 15 checks, all passing; `adopt` and `busytabs` still pass.

Original plan:

- **On quit, update or "close but keep the shell":** for each kept tab, read `ghostty_surface_recent_output`, send it as a `P` frame, then close the socket. The daemon goes back to reading the terminal.
- **Crash:** every 5 s, on a background queue, send a `P` snapshot for tabs whose output changed. A crash then loses at most the last 5 s of history, never the shell.

## Phase 5: tests and release, about 0.5 to 1 day. Done (27 Nov), ready for 6.2.18 (not yet published)

What landed:
- `ANSER_SELFTEST_ONLY=keptperf`: 50 MB through a kept tab and a plain tab in one run, alternating, best of three. First run: 0.31 s vs 0.31 s (1.02×); the check is ≤ 1.3×.
- `scripts/test-crash-relaunch.sh` (part of full `scripts/selftest.sh` runs):
  - kill -9 after a snapshot, relaunch, and check the shell is alive, reattaches directly, shows its history and is the same shell (`crash1` / `crash2` subsets);
  - a helper started with `ANSER_SESSION_IGNORE_DIRECT=1` in its own folder (`ANSER_SELFTEST_SESSIONS`), where tabs fall back to `attach` and only the first waits for the handoff (`fallback` subset).
- When a helper doesn't hand over (one from an older Anser after an update), Anser remembers its pid and later tabs skip the 1 s wait while it's running.
- `SELFTEST_TIMEOUT` raises `scripts/selftest.sh`'s 300 s limit (the full run is longer now).
- Decisions taken as recommended: shipped without the iTerm2 picture conversion in direct tabs (follow-up: port it into the Ghostty patch's iTerm2 `File=` handler); `attach` stays as the permanent fallback.

Original plan:

- **New perf check:** in one run, stream 50 MB in a kept tab and in a plain tab (switch the setting between tabs). Check that kept ≤ 1.3× plain.
- **Existing self-tests that must still pass:** reattach after restart, Running sidebar, busy-tab close, close-freeze (`busytabs` subset and `test-session-helper.sh`), resize, full-screen programs after reattach.
- **New tests:**
  - kill -9 the test app, relaunch, and check the shell is alive and its history is shown;
  - force the fallback (a daemon that ignores `direct`) and check tabs still work.
- Full `scripts/selftest.sh` with `caffeinate`, plus `swift test`.

**Total:** about 4 days.

## Decisions needed

1. **iTerm2-style pictures.** The `attach` helper turns them into kitty pictures, and Ghostty only parses them, it doesn't draw them. Anser's own `imgcat` already sends kitty pictures, so only third-party iTerm2 tools are affected.
   - **Recommended:** ship without the conversion in direct tabs first, then port it into the Ghostty patch, in its iTerm2 `File=` handler.
   - **Alternative:** port it before shipping, about 1 more day.
2. **Fallback path.** Recommended: keep `attach` permanently as the fallback. It costs nothing and covers older daemons after an update.

## Risks

- **Patch upkeep:** the Ghostty patch touches `Exec.zig`, which upstream changes often, so each Ghostty update may need the patch refreshed.
- **fd ownership:** Ghostty, Anser and the daemon each hold the terminal. A double close or a leaked fd would show as tabs that never close or shells that never end. Phase 1's test and the close tests cover this.
- **Crash history:** up to 5 s of output can be missing from history after a crash. The shell itself is never lost.
