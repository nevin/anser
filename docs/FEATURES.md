# Anser features

The [README](../README.md) has the short version. This is the full list.

## Saved commands: the Command Notebook

- **One place for reusable commands.** The **Saved panel** (⌥⌘N, or the book button at the right of the tab bar) holds your notebook commands in groups, then your runbooks. **Workflows are notebook entries with several steps**: they show as Notebook groups (yours, and the current project's from its `.anser` folder) everywhere, and **Tools → Run from Notebook (⌥⌘R)** runs any of them. One search covers it all.
- **Each panel has one job.** The left sidebar is about where you are and what's running (git, servers, tasks, containers, folders, hosts); everything saved lives in the Saved panel, so nothing shows twice. While the Saved panel is closed, the sidebar ends with a single **Saved commands** link that opens it. The Library (⌥⌘O, also a button in the Saved panel) manages everything, aliases, history and recordings included. **Tools → Manage** opens the Notebook, Aliases, History and Secrets editors as tabs of the Library window instead of separate windows.
- **Values to fill in.** A command with `{{name}}` or `{{name:default}}` asks for the values when you run it, like a workflow. Clicking it instead puts it in the editor, where Tab moves between the values.
- **Save from anywhere:** ⌥⌘S saves the command in the editor (or the last one), and every command block has a book button.
- **Old config snippets moved in.** The `snippets` from `config.json` were copied into a "Snippets" group once. `snippet:<name>` keybindings now find notebook entries by title.
- **Sync it.** Settings → Privacy & History → "Keep the Command Notebook in" puts it in iCloud Drive or any folder, such as a git repo you share. When the file changes elsewhere, Anser reloads it. Moving it merges with a notebook already there and never overwrites it.
- **Completion and the palette** offer named notebook entries.

## Finding things again

- **Search what commands printed.** Go → Search Output (⌥⇧⌘F), or the Output scope in Search (⌘R then ⇥). Output is stored on this Mac with secrets removed: the last 32,000 characters of each command, for your last 3,000 commands. Forgetting a command in History forgets its output. Turn it off in Settings → Privacy & History.
- **Notifications that take you back.** When a command that ran 10 seconds or more finishes while you can't see it (another app, another window or another tab), a notification appears. Clicking it opens that tab.

## Places that need care: profiles

Settings → Profiles (or `"profiles"` in `config.json`) applies settings by ssh host or folder:

```json
"profiles": [
  { "host": "prod-*", "tabColor": "red", "badge": "PROD", "confirm": ["*"] },
  { "folder": "~/work/payments", "badge": "payments", "env": { "AWS_PROFILE": "payments" } }
]
```

- `tabColor` colors the tab (red, orange, yellow, green, blue, purple, teal). A color you pick yourself still wins.
- `badge` shows in the status row.
- `confirm` asks before running matching commands there (`*` asks for every command, `*rm -rf*` only for those).
- `env` adds environment variables to new tabs opened in that folder.

## The command editor

- **Input bar placement.** The input bar stays at the bottom by default. Enable **Settings → Editor → Move the input bar up to follow short output** to place it below the live prompt when there is room.

- **Mistakes as you type.** Once you move past it, a command that doesn't exist gets a red dotted underline, with "Did you mean…" in the status row. So does a quote or bracket left open.
- **Bracket matching.** The bracket matching the one beside the cursor is highlighted.
- **Risky commands get an orange underline and a note:** force push (use `--force-with-lease`), `git reset --hard`, `git clean -f`, `curl … | sh`, `chmod 777`, `DROP TABLE`.
- **Commands that can destroy a lot ask before running:** `rm -rf /` or `~`, `dd` onto a disk, formatting a disk, fork bombs. Turn all this off in Settings → Editor.
- **More cursors.**
  - ⌥-click adds a cursor; ⌥-drag puts one on every line, in a column.
  - ⌥⌘G selects the next match of the selection, or the word at the cursor (macOS keeps ⌥⌘D for hiding the Dock). ⌃⌘G selects every match.
  - Typing, delete and paste go to all of them. Pasting as many lines as there are cursors puts one line at each. Esc goes back to one cursor.
- **Line editing:** ⌘/ comments lines out and back in. ⇧⌥↓ / ⇧⌥↑ duplicates them. ⌃⌘↑ / ⌃⌘↓ moves them.
- **Describe it, get the command.** Type `# find files over 100 MB changed this week` and press Tab. The AI you chose (Claude, Copilot or a local model) replaces your words with the command, for you to check before pressing ⏎. ⌘Z brings your words back.
- **⌃R** shows matching history right under the editor as you type; ⌃R again goes to older matches. ⌘R still opens the full history search.
- **Vim keys** (Settings → Editor):
  - Esc switches to normal mode, where the cursor turns into a block.
  - Moving: h j k l, w b e, 0 $, gg G. Editing: x, dd, dw, cw, cc, C, D, r, ~.
  - Back to typing: i a I A o O. Undo and redo: u and ⌃R. Copy and paste: yy, p, P.
  - / opens ⌃R history, and ⏎ runs the command.

## Shells that survive restarts and updates

- **Quitting Anser no longer stops your shells.** Builds, servers, ssh sessions and anything else running keep going. When Anser opens again, or after an automatic update, each tab comes back connected to the same shell, with its recent output (the last 2 MB) shown again and full-screen programs like vim redrawn.
- **Closing a tab or pane still ends its shell**, as before.
- **Command drafts** reopen with their panes and cursor positions. Anser saves local drafts that pass its secret checks and skips panes with history paused. Turn this off under Settings → Sessions & Windows → Remember unfinished local commands when reopening windows.
- **To end everything:** hold ⌥ in the Anser menu for **Quit and End All Shells**. Settings → Sessions & Windows → "Keep shells running when Anser quits or updates" turns it off.
- **Crashes too:** windows and shells are saved every 20 seconds, so a crash or forced quit brings them back too. Shells no window came back to are ended on the next launch.
- **How it works:** a small helper, `anser-session` (inside the app), holds each shell on its own pseudo-terminal. Each pane connects to it through a socket only your user can open. When the pane can't draw output fast enough, the program waits, as in any terminal, so nothing is dropped.

## While commands run

- **Waiting for you.** When a running program asks a question and waits — `[y/N]`, a password or passphrase, "Press any key", or an AI agent like Claude Code asking to approve a step — the tab gets an orange dot and the status row shows "waiting for y/n" (or similar). If you can't see that tab, a notification takes you there. Settings → Notifications turns it off.
- **Running servers.** A server a tab started (anything listening on a port: `npm run dev`, `python -m http.server`, `rails s`) shows as a green `:3000` chip. Click it to open it in the browser, copy the link or stop it. The sidebar's **Servers** section lists them across all windows. **Shell → Kill Process on Port…** shows what's using a port and stops it after you confirm.
- **Cloud context chip.** When you type or run `kubectl`, `helm`, `aws`, `terraform`, `docker` or `gcloud`, a chip shows where they'll act: `prod-eu/payments · aws:admin`. Click it to switch Kubernetes context or AWS profile. Settings → Suggestions & Helpers sets when it shows (when you type those tools, always, or never).
- **Profiles for clusters and accounts.** In Settings → Profiles, `kube:prod-*` or `aws:prod*` as the match colors the chip with the profile's badge, and "Ask before running" patterns (like `*delete*`) apply to commands that talk to that cluster or account.
- **Filter Output (⌃⌘O, in the Output menu).** A panel over the terminal filters the running (or last) command's output as it streams: words in any order or a regular expression, All / Warnings / Errors, repeated lines folded into one with a count, and Pause.
- **SSH that reconnects.** When an `ssh` session drops (exit 255 after it was up), a chip counts down and Anser reconnects by itself, waiting for the network if it's down, up to 6 tries. It adds keep-alives so a dead connection is noticed quickly. Click the chip to reconnect now or stop. Settings → Suggestions & Helpers can make it ask instead.

## Output as data

- **Compare with Previous Run.** The ⇄ button on a command's hover strip (or Shell → Compare with Previous Run) shows what changed since the last time you ran the same command, in this tab or from history: removed lines in red, added in green. "Ignore numbers and times" (on by default) skips lines that differ only in durations, counts or ids; "Changes only" hides the rest.
- **View as Table / JSON.** The table button on the hover strip (or Shell → View Output as Table / JSON) opens JSON as a tree, and CSV, TSV, JSON lines or column output (`kubectl get`, `docker ps`, `ps aux`) as a table you can sort by any column (numbers and sizes sort as numbers), filter and copy as CSV.

## Project tasks

- The sidebar's **Tasks** section lists what you can run in the current project: `package.json` scripts (with npm, yarn, pnpm or bun, from the lock file), Make targets, just recipes, Taskfile tasks, Procfile processes, and Cargo, Swift and Go basics. Click to run (in a new tab if this one is busy); right-click to run in a new tab, put it in the editor or copy it.

## Secrets in commands

- Write `{{secret:github-token}}` in any command, notebook entry or workflow. The first time, Anser asks for the value and keeps it in your login Keychain. When the command runs, the value is handed over through a one-time pipe: it never appears in the command line, history, the notebook or on screen. History keeps `{{secret:github-token}}`, so re-running works.
- `{{op://vault/item/field}}` reads from 1Password with its `op` tool.
- **Tools → Secrets…** lists the names, and lets you replace, copy a reference or delete. Keychain secrets work in local shells; on servers use `{{op://…}}`.

## Your history on all your Macs

- Settings → Privacy & History → "Share command history between my Macs" keeps history in step through iCloud Drive/Anser, the notebook's synced folder, or `"syncFolder"` in the config. Each Mac only adds to its own file there, so nothing conflicts. Commands that look like secrets were never saved, and output isn't shared. It syncs at launch, every 5 minutes and when you quit; **Tools → Sync History Now** does it on demand.

## Plugins

- **Extend Anser with small scripts.** A folder in `~/.config/anser/plugins` with a `plugin.json` can add status-row chips, command palette actions, sidebar sections, and hooks that run after commands. Plugins are off until you turn them on in **Settings → Plugins** (or **Tools → Plugins…**), which also makes an example to start from and adds **starter plugins** (Node version, Python environment, pull requests, TODO count, long command log). Plugins can have **settings** (secret ones go in the Keychain), and a repo can ship **project plugins** in `.anser/plugins` that run once you trust them. The full guide is in [PLUGINS.md](PLUGINS.md).

## Finding things

- **Right-click any command** in the terminal (the command line or its output) for everything you can do with it, in one menu: run again, edit and run, explain a failure, copy output or command, open the output in a window, view it as a table, compare with the previous run, open it in the log viewer, save it to the Notebook, make it an alias, watch its output, re-run it when files change, find it in the History Editor, share or export it.
- **Library** (Tools → Library…, ⌥⌘O) keeps everything you've saved in one window: Notebook (workflows included), Runbooks, Aliases, History, Recordings and Watching, with one search across them. The Notebook, Aliases, History and Secrets editors open as tabs of this window. Double-click (or Return) does the main thing (put in editor, run, open, replay); right-click for the rest; **Manage…** opens the full editor for that kind. Empty sections say what they're for.
- **Command palette** (⇧⌘P) shows each action's area (History, Git, Servers…) and shortcut, puts what you used recently first, and also finds actions by what they're for: “typo” finds Edit History, “port” finds the tunnel and port actions, “record” finds tab recording.
- **The sidebar is yours**: right-click a section heading to move it up, down or to the top, or to hide it. Hidden sections are listed at the bottom, ready to bring back; “Reset Sidebar” puts everything back.

## Menus, forms, Settings and the tour

- **Tidier menus**: **Shell** is for tabs, panes and running (with **Run and Watch**, **Remote** and **Command Editor** submenus). The **Output** menu has everything about what commands printed: filter, log viewer, compare, view as table, export, share and record. **Go** starts with Search. **Tools** has Library, Saved Panel, Save, Run from Notebook and Runbooks, then **Manage** (Notebook, Aliases, History, Secrets, Plugins), **Create**, **Servers** and AI.
- **Shortcuts follow a scheme**: ⌘ for everyday things, ⇧⌘ for the bigger version (all tabs, deep clean) and git, ⌥⌘ for saved commands (⌥⌘N Saved panel, ⌥⌘S save, ⌥⌘R run, ⌥⌘O Library, ⌥⌘A aliases), and ⌃⌘ for windows and panels (⌃⌘S sidebar, ⌃⌘H history, ⌃⌘O filter output, ⌃⌘L log viewer, ⌃⌘W watch, ⌃⌘R record). The ⌘/ sheet is grouped the same way. Filter Output moved from ⌥⌘L to ⌃⌘O; the old shortcut still works for now.
- **Forms that check as you type**: adding an alias or a tunnel, watching a command, "when this finishes" and new runbooks use proper sheets. Save stays off with a red note until the values work (a name that's taken, a port out of range), an orange note warns without blocking (the name is already a command, the port is in use), and a preview shows the result (`glog …  →  git log --oneline …`, the exact ssh command).
- **Settings** has a sidebar with an icon per section and a line at the top of each saying what's in it; search is at the top of the sidebar. What used to be one long Behavior page is split by purpose: **Notifications**, **Suggestions & Helpers** (including when the cloud context chip shows and which editor opens ⌘-clicked files), **Privacy & History** and **Sessions & Windows** (including the quick terminal's height).
- **Help → Take the Tour** (also on the What's New window and the first-launch welcome card): five short pages on the editor, right-click, the status row colors, finding things, and the sidebar.
- **Empty lists say what they're for** (Library sections, the History Editor's filters, the Log Viewer before any lines arrive), with a button to get started where there is one.

## A calm status row

- Chips have one color per meaning: **red** something went wrong, **orange** something is waiting (on you, or queued to run), **blue** information (servers, watching, a loaded environment), **green** a suggestion (an alias, a fix, loading a `.env`).
- At most four chips show besides the folder and branch, most important first; the rest go under a **+N** chip (orange when one of them needs attention). **REC**, **Sharing** and **all panes** never go under +N, since they change who sees the tab or where typing goes.
- Suggestions fade after 20 seconds so they don't nag; move the mouse over one to bring it back. With Reduce Motion or Increase Contrast on (System Settings → Accessibility), they don't fade.

## Tests, watching and "when this finishes"

- **Failed tests, one click away.** After pytest, Jest, Vitest, `go test`, `swift test`, `cargo test`, RSpec, `dotnet test`, PHPUnit, ExUnit (`mix test`) or JUnit through Gradle or Maven fails (directly or through `npm test`, `make test`…), a red **“3 tests failed”** chip and a **Failed tests** sidebar section list them. Click one to open its file at the failing line; ▶ re-runs just that test. Re-run them until they pass and the list empties. Turn it off in Settings → Suggestions & Helpers.
- **Re-run when files change.** Shell → Re-run When Files Change (or the … menu) repeats the last command whenever a file in the project changes. Build output, `node_modules`, `.git`, caches and editor temp files don't count, so a build can't trigger itself. A blue **watching** chip shows how many runs; click it to run now, limit it to some files (`*.py, *.toml`, `src/`) or stop.
- **When this finishes…** While a command runs: notify me, run another command next, or run it only if this one succeeds (Shell menu, or the … menu). A yellow chip shows what's queued.

## Project environments

- When you `cd` into a project with a `.env`, a Python virtualenv (`.venv`, `venv`), an `.nvmrc`/`.node-version` (with nvm or fnm) or an `.envrc` (with direnv), a **Load** chip offers to load it. It loads silently (nothing typed, nothing in history) and unloads when you leave the folder. Choose **Always Load in This Project** or **Don't Offer in This Project** from the chip.
- `.env` values are read by Anser and set with `export`; the file is never run. Variables that would change which programs run (`PATH`, `DYLD_*`, `LD_*`…) are skipped. Shells opened before this version need a new tab.

## Runbooks

- A runbook is a Markdown file whose shell code blocks are steps: deploys, onboarding, incident checklists. Open one from **Tools → Runbooks…** or the Saved panel and it sits beside the terminal with a **Run** button per step; each step gets a tick or a cross with its time. **Run the Rest** goes on until something fails. `{{name}}` asks for a value once per run. **Edit** changes the Markdown right in the window (ticks stay on steps you didn't change).
- Yours live in `~/.config/anser/runbooks`; a repo's in `.anser/runbooks` are shared with the team and, like project workflows, run only after you've seen and trusted them (any change asks again). **Tools → New Runbook…** starts one from a template.

## Containers, pods and tunnels

- **Containers** in the sidebar (while Docker runs): click for logs, ⌘-icon for a shell inside, right-click to restart, stop, start or open its port.
- **Pods** in the current Kubernetes context: listed only when you click **Load pods** (the cluster may be far away). Unhealthy pods come first; click for logs, right-click for a shell or `describe`.
- **SSH tunnels**: Tools → Add SSH Tunnel… keeps a port forward open in the background (and reopens it when it drops), optionally from launch. The sidebar's **Tunnels** section opens and closes them. Background tunnels need a key or ssh-agent; “Open in Terminal” works with passwords.
- **Copy files over ssh**: drop files on an ssh tab to upload them to the folder you're in there, or use Shell → Upload Files to Server… / Download File from Server… (to Downloads). It reuses the ssh command's port, key and jump host.

## AI tasks, step by step

- **Tools → Do a Task with AI, Step by Step…**: describe a goal (“find why the build is slow”). The AI proposes one command at a time with a reason; you Run (⌘↩), edit, Skip or Stop. It sees each command's result before suggesting the next, can ask you a question, and finishes with a summary. Risky commands (deleting files, force-pushing, changing a cluster) are flagged in red. Nothing runs without your click, and secrets are removed before anything is sent.

## Aliases and habits

- **Tools → Aliases…** manages your aliases: add, edit (double-click) and delete, with the name checked as you type. They're saved in `~/.config/anser/aliases.json` and work in every open tab at once, then in every new one (zsh, bash and fish). Aliases from your own `.zshrc`/`.bashrc` are listed too, so you can see which names are taken.
- **Groups and import**: give aliases a group (git, docker…) to keep them together, and **Import from Shell…** copies the aliases from your `.zshrc`/`.bashrc` into Anser so you can manage them in one place (Anser's copies load after your own files, so edits here win).
- **Suggestions from your habits**: the same window lists long commands you keep typing, each with a short name (`git log --oneline --graph` → `glog`). Commands that failed, contain secrets or are just a `cd` are left out. After you type one again, a blue **“Make it an alias”** chip offers it; if you already have an alias for that exact command, the chip reminds you of it. Turn tips off in Settings → Suggestions & Helpers.

## Remembering fixes, watching output, many servers

- **“Last time this failed, you ran…”** When a command fails and it failed before, Anser looks at what you ran in that tab between the earlier failure and the run that worked, and offers it as a green chip: run the fix, run it and retry, or put it in the editor. It all comes from your own history; nothing is sent anywhere.
- **Watch a command's output** (Shell menu): Anser runs a command in the background every minute, 5 or 15 minutes or hourly, and notifies you only when its output changes, it starts failing or it works again. Times and ages in the output (“12:04:01”, “5m”) don't count as changes. The sidebar's **Watching** section shows each one; click to see exactly what changed.
- **Run on Several Servers** (Tools menu): tick ssh hosts (from `~/.ssh/config`, or add any), type a command, and it runs on up to 8 at a time. Results show side by side with failures and unreachable hosts first; click one for its full output. Save a set of hosts as a group for next time. It needs a key or ssh-agent, since there's no terminal to type a password.
- **Open a server's port on this Mac**: when a program in an ssh tab prints that it's listening (`http://localhost:3000`, “listening on 8080”), a chip offers to forward that port through the same ssh connection and open it in your browser. Shell → Open a Server Port on This Mac… does it for any port. Forwards stop when the ssh session ends.
- **AI gray text (optional)**: with a local Ollama model set up in Settings → AI, Settings → Editor → “ask a local AI model” fills the gray suggestion when your history has nothing. It stays on your Mac.

## Editing history

- **Tools → Manage → History…** (⌃⌘H, a tab of the Library) lists every command in your history with how often you ran it and when. Search it, filter it (mistakes, basic commands, last run failed, not used for 6 months; the filter menu shows how many each has) and sort by any column. The list runs the full height of the window, with an inspector beside it. Its Notes column flags mistakes in orange and failed last runs in red.
- **The inspector** on the right shows what you selected. With nothing selected it shows the last 30 days as a chart, your most-used commands (click one to select it), your busiest folders, and a **Tidy up** list (typos, basic commands, failed, unused for 6 months, Recently Deleted, size on disk) with a button that filters the list to each. Select a command and its actions come first (Put in Editor, Run, Edit, Save to Notebook, Copy, Delete), then its track record (runs, how often it worked, how long it usually takes, first and last use), its recent runs (when, how long, exit code, branch, and the folder when it changes), its last output, its own 30-day chart, and the folders and branches it ran in. A typo or a command that wasn't found offers **Fix Typo** (`gti status` → `git status`). Select several for a breakdown and bulk actions.
- Filter to **Used in this folder** to see just this project's commands.
- **Save to Notebook** (or ⌘S) saves the selected commands to the Command Notebook, into a group you pick or a new one; one command can get a title. Commands already in the notebook are skipped. The same is in history search (⌃R): select a command and click **Save to Notebook…**, or right-click it.
- **Edit Command…** (right-click) fixes a command's text in every run, for a typo or a secret you pasted by mistake; if the fixed text is already in history, they merge. Return puts the selected command in the editor, ⌘Return runs it.
- **Show Mistakes** (in the side panel's Tidy up, or the filter menu) lists typos (`gti status`, `dokcer ps`: a program that doesn't exist but is one or two letters from one that does, and that the shell couldn't run; `npm run biuld` isn't flagged as a typo of `nm`, because npm ran), commands the shell couldn't find, and commands that ran once and failed. **Show Basic** lists clutter like `ls`, `pwd`, `clear` and `cd ..`. On a filtered list the side panel offers **Select All**; adjust the selection with ⌘-click and ⇧-click, then **Delete** (or ⌫) removes every run of each, with its saved output, after asking.
- Deleted commands go to **Recently deleted** (in the filter menu) for 7 days, where **Restore** puts them back and **Empty** removes them for good. Tick “Delete permanently” when a command had a secret in it.
- Settings → Privacy & History → “Once a week, move typos in my history to Recently Deleted” keeps it tidy by itself (only clear typos and commands that were never found).
- **Compact…** shrinks history in one go: delete the mistakes found, delete basic commands, keep only the newest 5–50 runs of each command, forget commands unused for months, and drop old saved output. It then reclaims the disk space and shows the size before and after.

## Log viewer

- **Shell → Log Viewer** (or the **Log view** chip while `tail -f`, `docker logs -f`, `kubectl logs -f`, `journalctl -f` or `stern` runs) shows a tab's logs in a window: levels in color, time and container/pod names picked out, and fields from JSON and `key=value` logs. Filter by level (stack traces stay with their error), search, expand JSON lines, pause, and jump to the next error with ⌘E. It keeps lines even after they scroll out of the terminal (up to 50,000). **Highlight** marks words or a `/regex/` (a request id, say) in yellow, **Saved Filters** keeps level + search + highlight under a name for any log, and **Export…** saves the lines shown.

## Recording a tab

- **Shell → Record This Tab** records what the tab shows until you stop it (a red **REC** chip shows the time). Stopping opens the replay: play, pause, scrub, 0.5–8× speed, skip idle time, and jump to each command that ran. **Share** exports a single **HTML player** file anyone can open in a browser, or an **asciinema `.cast`**, with tokens and passwords blanked out by default. Recordings are kept in `~/Library/Application Support/Anser/recordings`; **Shell → Open Recording…** opens one. **Share → Trim: Start Here / End Here** cuts the recording down before you share it. Recordings are text, so colors aren't kept: the terminal engine only hands out plain text.

## Sharing one command

- **Share Command and Output** (the link button on a command's hover strip, or the Shell menu) shows the command and its output as Markdown with secrets removed. You can edit it, then copy it or create a **secret GitHub gist** link (needs the GitHub CLI, `gh`, signed in).

## Links, Shortcuts and Finder

- **`anser://` links** for Shortcuts, Raycast, Alfred and scripts: `anser://new?dir=~/code/app` opens a tab there (`&window=1` for a window), and `anser://run?dir=~/code/app&cmd=make%20test` runs a command in a new tab after you confirm it (any web page can open a link, so it always asks).
- **Finder → Services → New Anser Tab Here** opens a tab in the selected folder (or a file's folder).

## Finding, timing and showing

- **Switch to Tab** searches tab names, folders, branches, and SSH hosts. Open it from All Tabs or the command palette (⇧⌘P). Press Tab to switch between This Window and All Windows.
- **One search (⌘R)** looks everywhere, one scope at a time (⇥ moves between them): All history, This folder, This tab, Failed, Output (what commands printed), All tabs (every command and its output in every window; choosing a result goes to that tab and highlights it) and Saved (Notebook, workflows and runbooks). ⌘B opens it on This tab, ⇧⌘F on All tabs and ⌥⇧⌘F on Output.
- **How long things take.** While a command runs, the status line shows how long it usually takes ("usually 40s", from its last successful runs), with a thin progress bar. It turns orange if this run is much slower than usual. History's preview shows the usual time and the range.
- **Pictures in the terminal.** Tools using the kitty graphics protocol show images directly. Images in iTerm2's format (what `imgcat` and many other tools print) are converted on the way in, so they show too. `imgcat FILE` works even if you haven't installed one.
- **Git blame.** Git → Blame File… (⌥⇧⌘L) lists every line with who changed it, when, and the commit message; the preview shows the commit. Right-click a file path printed in the output (`src/app.swift:42`) for Blame Line 42, Open, Quick Look, Show in Finder or Copy Path.

## Folders and splits

- **Right-click a folder** in Jump to Folder (⌘J), on the folder chip under the editor, or in the sidebar's recent folders:
  - **cd Here** (in a new tab if something is running), **New Tab Here**, **New Window Here**, **Open in Finder**, **Copy Path**.
  - After those: Open in Editor, Quick Look, and (in Jump to Folder) **Files ▸** to open anything inside.
- **Named workspaces.** Use Window → Save Window as Workspace to save your tabs, split sizes, folders, and tab colors. Window → Open Workspace previews the layout and focuses its window when already open. Use Actions → Pin to keep a workspace at the top. Pinned and recent workspaces also appear in the command palette. Opening a closed workspace starts fresh shells. Anser applies the profiles configured for those folders.
- **Splits in four directions:** Shell → Split Right (⌘D), Split Down (⇧⌘D), **Split Left** and **Split Up**. They're also in the right-click menu of the terminal and in the command palette.

## Memory

- **Saved output has a budget.** Each tab keeps at most 12 MB of command output in memory: up to 1 MB for the newest command, and the last 64 KB of older ones. Before, a long session could keep hundreds of MB. Full output stays in the terminal's scrollback, and its end is saved for History → Output search.
- **Clipboard history skips huge copies** (over 1 MB) and keeps 16 MB at most.
- **Freed memory goes back to macOS** after big output, after closing a tab or Deep Clean, and 10 seconds after you switch to another app.
- **When macOS reports memory pressure,** Anser keeps far less output, drops caches and trims clipboard history right away.
- **Scrollback per tab** (Settings → Sessions & Windows: 2, 10, 50 or 100 MB) is the biggest cost when many tabs are open. Lower it if you keep lots of tabs.
- **Help → Report a Problem** shows Anser's memory now and at its peak, and how long the last startup took (also written to `~/Library/Logs/Anser/anser.log`).
- **Battery.** Anser checks the clipboard less often while it's in the background, updates hidden tabs' running timers less often, and skips the 20-second window save when nothing changed.

## Clear and Deep Clean

- **Clear (⌘K)** wipes the screen and scrollback. It also wipes the copy kept for restarts, so old output doesn't come back. The tab's command list (⌘B) stays.
- **Deep Clean (⇧⌘K)** runs immediately from the shortcut or the View menu. It:
  - resets the terminal, which fixes garbled characters, a missing cursor or odd colors after printing a binary file;
  - clears the screen and scrollback;
  - forgets this tab's command list and their captured output.
- **Deep Clean…** in the pane’s “…” menu or terminal right-click menu opens the dialog with an option to also remove those commands and their saved output from History.
- **Your shell keeps running,** with its folder, variables and anything in progress.

## Sharing a tab (read-only)

- **Shell → Share This Tab (Read-Only)…** copies a link. Anyone on your network who has it can watch the tab's screen live in their browser. They can't type anything.
- **The link** has a long random secret. The page can't be embedded in other sites. Up to 20 people can watch at once.
- **A code, too.** By default viewers also type a 4-digit code you tell them, so the link alone isn't enough. After 10 wrong codes, sharing stops.
- **When it stops:** when you stop it (click the blue "Sharing" chip), close the tab, quit, or after 2 hours.
- **Be aware** that it isn't encrypted, so use it on networks you trust. macOS may ask once whether Anser can accept incoming connections.

## Previews and hosts

- **Quick Look on hover.** Rest the mouse on a file path printed in the output, like `src/app.swift:42` from a compiler or a file `ls` listed, and a preview appears. Move away and it closes. Turn it off in Settings → Suggestions & Helpers.
- **SSH hosts in the sidebar**, from `~/.ssh/config` and the files it includes. Click a host to connect in a new tab. A host with a profile shows its color and badge.
- **Profiles apply as soon as you connect.** Running `ssh prod-web` colors the tab and shows the badge right away, matching the name you typed or its real host name from your ssh config, even on servers without Anser's hooks.

## Working across panes and apps

- **Quick terminal.** Settings → Sessions & Windows → Quick terminal sets a shortcut (for example ⌃`) that drops a terminal down from the top of the screen in any app. Press it again to go back to where you were. Its height is set right below it (20–90% of the screen).
- **Type in all panes.** Shell → Type in All Panes of This Tab (⌥⇧⌘B): commands you run from the editor, and Stop, go to every pane in the tab. A yellow "all panes" chip shows while it's on; click it to stop.

## Git

- **Pull requests.** With the GitHub CLI (`gh`) signed in, the branch's pull request shows next to the branch: `#42 ✓` when checks pass, `#42 ✗` when they fail, `#42 …` while they run. Click it to open the PR. Git → Open Pull Request offers to create one. Turn it off with `"showPullRequests": false`.
- **Merge conflicts.** During a merge, rebase, cherry-pick or revert with conflicts, a red chip shows the count. Click it, or use Git → Resolve Conflicts…, for the list of files with their diffs:
  - ⏎ opens the file in your editor.
  - ⌥⏎ keeps your version.
  - ⇧⏎ keeps theirs.
  - ⌘⏎ marks it resolved.

  The list also offers Continue and Abort. "Yours" means your branch even in a rebase, where git's ours and theirs are swapped. Every action runs as a normal command in the tab, so you can see it.

## AI help (off by default)

- **Choose who answers** in Settings → AI:
  - **Claude** uses your Anthropic API key, kept in the Keychain.
  - **GitHub Copilot** uses its CLI with every tool turned off, so it can only answer.
  - **Local AI with Ollama** runs on this Mac, and nothing leaves it. Settings can install Ollama, start it, download a coding model and test it.
- **Explain any failure:** the ✨ button on a failed command's hover strip, the Explain chip, or ⌥⌘I.
- **Fix & Retry** runs a suggested fix. **Insert** puts it in the editor first. Nothing runs unless you click.
- **Before anything is sent:** things that look like secrets are removed from output, and the panel says where the request goes.

## Coming from another terminal

App menu → Import from iTerm2 or Warp…:

- **From iTerm2:** each profile's colors (as Ghostty themes) and the default profile's font.
- **From Warp:** custom themes, font and workflows (into a "From Warp" notebook group, with argument defaults kept).

You can switch to the imported theme and font in the same step. Themes go to `~/.config/ghostty/themes`.

## Default terminal

- **Anser menu → Make Anser the Default Terminal.** After this, `.command` and `.tool` scripts you double-click in Finder, `ssh://` links and manual-page links open in Anser. macOS may ask you to confirm each one. Choose the same item again to switch back to Apple's Terminal.
- **Downloaded scripts ask first.** A script downloaded from the internet asks before it runs.
- **Links are checked strictly.** An ssh link that isn't a plain `user@host:port` is refused, so a web page can't slip options into `ssh`.
- **Folders:** drop one on the Dock icon to open a tab there. Right-click the Dock icon for New Window and New Tab.

## Learning as you go

- **One-time tips** appear at the moment they help. Examples:
  - After pressing ↑ six times: "⌘R searches all your history".
  - After typing `history | grep`, the same tip.
  - After running the same long command four times: "⌥⌘S saves it to your notebook".
- **Each tip shows once, at most one every 10 minutes.** Settings → Editor → Keyboard tips turns them off.

## Your usage, on your Mac

- **Off unless you turn it on.** Help → Your Feature Usage counts which features you use, per day, for 90 days. The counts are kept in `~/Library/Application Support/Anser/usage.json` and never sent anywhere.
- **Shared only when you choose:** if counting is on, Help → Report a Problem includes the counts in the report you review before sharing.

## Updates

- Anser menu → Check for Updates uses Sparkle. Builds made after `scripts/setup-updates.sh` check automatically and verify each update's signature. The switch is in Settings → Sessions & Windows. See [RELEASING.md](RELEASING.md).

## Everything else

- **Command editor.** You type commands in a real macOS text field: select with the mouse or Shift/Option-arrows, type over a selection to replace it, drag to select, ⌘Z undo, Option-delete words. Enter runs the command. Shift/Option-Enter adds a new line.
- **Editor extras:**
  - Quotes and brackets close themselves, and typing one over a selection wraps it.
  - Double-click selects a whole path or flag; ⌥↑ / ⌥↓ grow or shrink the selection (word → command → line).
  - ⌥⌘F splits a long command into one pipe stage per line (or joins it back), and multi-line commands show line numbers.
  - ⇧⌘E gives a tall editor; ⌥⌘E opens the command in `$EDITOR` and brings it back when you quit.
  - A hint line explains the word under the cursor (`git commit -m ‹message›  Commit message`).
- **Autocomplete popup** as you type. Sources: history, commands on your PATH, aliases, functions, files and folders, plus git (branches, changed files, commits, stashes, remotes, tags), npm/yarn scripts, Make targets, SSH hosts, docker, brew, kubectl, gh and more. Commands without a spec get their flags from `--help` or the man page.
- **Ghost text.** Your best history match shows in gray. → accepts all of it, ⌥→ accepts one word.
- **History.** Every command is stored in SQLite with folder, exit code, duration and git branch. Your zsh/bash history is imported on first run. ↑/↓ steps through commands starting with what you've typed. ⌘R/⌃R opens fuzzy search, filtered by All, This folder, This tab or Failed.
- **Smart copy/paste.** ⇧⌘C copies the last command's output exactly. ⌥⌘C copies the last command. In the history list, ⌥⏎ copies any earlier command's output. ⇧⌘V opens clipboard history. Files pasted or dropped in become escaped paths. Multi-line pastes stay in the editor until you run them.
- **One input.** By default the shell's own waiting prompt is hidden, so the editor is the only place you type, and each command stays in the scrollback as `❯ command`. Settings → Shell prompt switches to a short `❯` or your own prompt. Turning the editor off (⌘E) always brings your prompt back.
- **Tabs** in Anser's own tab bar:
  - Double-click a tab (or press ⇧⌘I) to rename it; right-click for colors and close options.
  - Drag tabs to reorder them (the others slide aside), or press ⌥⌘← / ⌥⌘→. Middle-click closes one.
  - Right-click → Move Tab to New Window keeps its shells running.
  - ⌘1–9 jump to a tab, ⇧⌘[ / ⇧⌘] switch to the previous or next one.
- **Splits:** ⌘D splits right, ⇧⌘D splits down, ⌘[ / ⌘] move between panes.
- **Appearance** (⌘,): font, text sizes, 725 color themes, background opacity, cursor shape and padding. Changes apply live.
- **Programmable.** `~/.config/anser/config.json` holds abbreviations, keybindings (`run:`, `insert:`, `snippet:`, `action:`, `ghostty:`), and extra Ghostty settings. Custom completions go in `~/.config/anser/completions/*.json`, and they can run scripts to produce suggestions. The config reloads when you save it.
- **A status row you can click:**
  - The folder chip opens recent folders (⌘J); Enter `cd`s there.
  - The branch chip switches branches, or creates one when you type a new name (⇧⌘B).
  - "3 changed" lists changed files: diff, stage/unstage, open (⇧⌘G).
  - The result chip offers retry and copy actions.
- **Help when things fail:** typos like `gti status` get a one-click "Did you mean: git status"; any failed command offers "Edit & retry". A Stop button appears while a command runs.
- **Discoverable:** ⌘/ shows every shortcut, and a short welcome card appears on first launch, with a button for the tour (Help → Take the Tour any time). After an update with new features, a What's New window lists them once (Help → What's New in Anser). Settings has a search box: type and press Return to jump to a setting.
- **Command blocks:** a colored bar beside each command and its output (green ok, red failed, yellow running). Hover a block for its exit code and duration, Run again, Copy output, Copy command, Save to Notebook, ✨ Explain (failed commands only) and **…** for everything else (the same menu as right-click).
- **⌘-click file paths** in output (`src/app.swift:42:10`, `main.go(7)`, Python tracebacks) to open them at that line in Cursor, VS Code, Zed or Sublime. Choose the editor in Settings → Suggestions & Helpers, including terminal editors like nvim.
- **Tabs show activity:** a spinner while a command runs, a red dot when one failed in the background, a blue dot when one finished. Narrow tabs get a ⌄ menu listing them all.
- **Previews in pickers:** diffs in Changed Files, output in Commands-in-this-tab, commit log plus ahead/behind in the branch switcher, folder contents in Jump to Folder.
- **Splits:** each pane gets a header (title, folder, zoom, close), the inactive pane is dimmed, and ⇧⌘↩ zooms a pane to full size and back.
- **Completion docs:** the full description of the highlighted suggestion appears beside the popup.
- **Sidebar** (⌃⌘S): git changes, servers, tasks, recent folders and more, one click each; saved commands are in the Saved panel (⌥⌘N).
- **Polish:** a ligatures on/off setting, recent actions first in the palette, VoiceOver labels throughout, and a status row that folds its buttons into "…" when narrow.
- **ssh:** `ssh host` from Anser brings the editor, completion and history into the remote zsh or bash. Hooks are unpacked into a temp folder for that session and deleted on logout; nothing is installed on the server. Completion skips your Mac's files while remote, and history entries are tagged `ssh://host/path`.
- **Workflows**: notebook entries with several steps and `{{parameters}}`, with dropdowns where you list options. Run them with everything else from **Tools → Run from Notebook (⌥⌘R)**. Personal ones live in `~/.config/anser/workflows/`; put them in a repo's `.anser/workflows/` to share with your team. Tools → Create → Save Several Commands to Notebook… makes one from this tab.
- **Export** a tab's commands and outputs as Markdown, JSON, PDF, HTML or text (⇧⌘S), or one command's output (⌥⇧⌘S).
- **AI help (off by default):** see above.
- **Open a command's output in its own window** from its hover strip: scroll, find (⌘F), copy or export it.
- **Problem reports:** crashes, UI hangs and recent activity are logged locally in `~/Library/Logs/Anser`. Help → Report a Problem builds a report you review and copy; nothing is uploaded.
- **Find** in scrollback with ⌘F, using Ghostty's own search.
- **This tab's commands** (⌘B, the This tab scope of Search): every command you ran, with exit status and duration. ⏎ jumps to it; ⌃Return opens its actions. Copy output, edit and retry, export, or save to Notebook. ⌘↑/⌘↓ jumps between prompts.
- **Safe by default:**
  - Anser asks before closing a pane, tab or the app while something is running.
  - Commands that look like they contain secrets (`*token=*`, `export *secret*` and similar) are never saved to history.
  - You can pause history per tab.
  - Flags for unknown commands are read from man pages; only well-known tools are ever run with `--help`.
- **Session restore:** windows, tabs, splits and their folders come back on relaunch.
- **Full-screen programs** (vim, less, htop, tmux…) get the whole window; the bar comes back at the prompt. That includes ones a command opens itself, like the pager behind `git branch` or `git log`, or the editor `git commit` starts, so q, the arrows and search reach them.
- **Stop that works.** Stop sends ⌃C. A pager (less, more, man…) is ended right away, since it ignores ⌃C. If a program is still running after ⌃C, the button turns into **Force Stop**: the next click ends it (SIGTERM, then SIGKILL).
- **Optional compact prompt** (`"compactPrompt": true`), since the bar already shows folder and branch.
- **Settings window** (⌘,) for the common options. Everything else lives in the config file.
- Your existing `~/.config/ghostty/config` (theme, font) is used automatically.


## More completions (optional)

Anser can lazily load the 700+ open-source [Fig autocomplete specs](https://github.com/withfig/autocomplete). Converting them runs the package's JavaScript, so it's a step you run yourself:

```sh
mkdir -p .build/fig && (cd .build/fig && npm pack @withfig/autocomplete && tar xzf withfig-autocomplete-*.tgz)
node scripts/import-fig-specs.mjs .build/fig/package Sources/AnserCore/Specs/fig
bash scripts/build-app.sh
```

Hand-written specs (git, common tools) still take priority over imported ones.

## Security

Anser treats program output and cloned repositories as untrusted:

- **ssh events need a secret.** Anser's remote hooks report through terminal titles, which any output can print. Each session gets a random token; events without it are dropped, so a file you `cat` can't fake history entries or a remote session. The token is kept out of the environment of programs you run.
- **Repos can't run code through Anser's git checks.** A `.git/config` can make git run programs (`core.fsmonitor`, filters, hooks, `diff.external` and more). Anser's own background git commands switch those off, and in a repo whose config sets them, automatic checks stop and the branch chip shows a shield. Running `git` yourself still behaves like normal git.
- **⌘-click never launches things.** Apps, `.command` and other scripts, installers and executable files are revealed in Finder instead of opened. Links printed by programs open directly only for http, https and mailto; other schemes ask first.
- **Project workflows ask before running.** Workflows in a repo's `.anser/workflows` show their steps and run only after "Trust & Run". Trust is tied to the file's contents, so any change asks again. Putting a workflow in the editor (⌥⏎) runs nothing and needs no trust.
- **Clipboard access asks.** Programs that try to write (OSC 52) or read your clipboard get a prompt. Change it with `clipboard-write = allow` in your `[ghostty]` lines.
- **The current folder comes from Anser's private channel.** Folder reports printed in output (OSC 7) are ignored when the hooks are active.

