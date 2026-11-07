# Anser features

The [README](../README.md) has the short version. This is the full list.

## Saved commands: the Command Notebook

- **One place for reusable commands.** The notebook (⌥⌘N opens it on the right of the window) holds your saved commands in groups, and lists your workflows below them: personal ones from `~/.config/anser/workflows` and the current project's `.anser/workflows`.
- **Values to fill in.** A command with `{{name}}` or `{{name:default}}` asks for the values when you run it, like a workflow. Clicking it instead puts it in the editor, where Tab moves between the values.
- **Save from anywhere:** ⌥⌘S saves the command in the editor (or the last one), and every command block has a book button.
- **Old config snippets moved in.** The `snippets` from `config.json` were copied into a "Snippets" group once. `snippet:<name>` keybindings now find notebook entries by title.
- **Sync it.** Settings → Behavior → "Keep the Command Notebook in" puts it in iCloud Drive or any folder, such as a git repo you share. When the file changes elsewhere, Anser reloads it. Moving it merges with a notebook already there and never overwrites it.
- **Completion and the palette** offer named notebook entries.

## Finding things again

- **Search what commands printed.** Go → Search Command Output (⌥⇧⌘F), or the Output scope in History (⌘R then ⇥). Output is stored on this Mac with secrets removed: the last 32,000 characters of each command, for your last 3,000 commands. Forgetting a command in History forgets its output. Turn it off in Settings → Behavior.
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

- **Mistakes as you type.** Once you move past it, a command that doesn't exist gets a red dotted underline, with "Did you mean…" in the status row. So does a quote or bracket left open.
- **Bracket matching.** The bracket matching the one beside the cursor is highlighted.
- **Risky commands get an orange underline and a note:** force push (use `--force-with-lease`), `git reset --hard`, `git clean -f`, `curl … | sh`, `chmod 777`, `DROP TABLE`.
- **Commands that can destroy a lot ask before running:** `rm -rf /` or `~`, `dd` onto a disk, formatting a disk, fork bombs. Turn all this off in Settings → Editor.
- **More cursors.**
  - ⌥-click adds a cursor; ⌥-drag puts one on every line, in a column.
  - ⌥⌘D selects the next match of the selection, or the word at the cursor. ⌃⌘G selects every match.
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
- **To end everything:** hold ⌥ in the Anser menu for **Quit and End All Shells**. Settings → Behavior → "Keep shells running when Anser quits or updates" turns it off.
- **Crashes too:** windows and shells are saved every 20 seconds, so a crash or forced quit brings them back too. Shells no window came back to are ended on the next launch.
- **How it works:** a small helper, `anser-session` (inside the app), holds each shell on its own pseudo-terminal. Each pane connects to it through a socket only your user can open. When the pane can't draw output fast enough, the program waits, as in any terminal, so nothing is dropped.

## Finding, timing and showing

- **Find in All Tabs (⇧⌘F)** searches every command and its output in every tab and window. Choosing a result goes to that tab and highlights it there.
- **How long things take.** While a command runs, the status line shows how long it usually takes ("usually 40s", from its last successful runs), with a thin progress bar. It turns orange if this run is much slower than usual. History's preview shows the usual time and the range.
- **Pictures in the terminal.** Tools using the kitty graphics protocol show images directly. Images in iTerm2's format (what `imgcat` and many other tools print) are converted on the way in, so they show too. `imgcat FILE` works even if you haven't installed one.
- **Git blame.** Git → Blame File… (⌥⇧⌘L) lists every line with who changed it, when, and the commit message; the preview shows the commit. Right-click a file path printed in the output (`src/app.swift:42`) for Blame Line 42, Open, Quick Look, Show in Finder or Copy Path.

## Folders and splits

- **Right-click a folder** in Jump to Folder (⌘J), on the folder chip under the editor, or in the sidebar's recent folders:
  - **cd Here** (in a new tab if something is running), **New Tab Here**, **New Window Here**, **Open in Finder**, **Copy Path**.
  - After those: Open in Editor, Quick Look, and (in Jump to Folder) **Files ▸** to open anything inside.
- **Splits in four directions:** Shell → Split Right (⌘D), Split Down (⇧⌘D), **Split Left** and **Split Up**. They're also in the right-click menu of the terminal and in the command palette.

## Memory

- **Saved output has a budget.** Each tab keeps at most 12 MB of command output in memory: up to 1 MB for the newest command, and the last 64 KB of older ones. Before, a long session could keep hundreds of MB. Full output stays in the terminal's scrollback, and its end is saved for History → Output search.
- **Clipboard history skips huge copies** (over 1 MB) and keeps 16 MB at most.
- **Freed memory goes back to macOS** after big output, after closing a tab or Deep Clean, and 10 seconds after you switch to another app.
- **When macOS reports memory pressure,** Anser keeps far less output, drops caches and trims clipboard history right away.
- **Scrollback per tab** (Settings → Behavior: 2, 10, 50 or 100 MB) is the biggest cost when many tabs are open. Lower it if you keep lots of tabs.
- **Help → Report a Problem** shows Anser's memory now and at its peak.

## Clear and Deep Clean

- **Clear (⌘K)** wipes the screen and scrollback. It also wipes the copy kept for restarts, so old output doesn't come back. The tab's command list (⌘B) stays.
- **Deep Clean… (⇧⌘K)**, also in the View menu, the "…" menu and right-click, asks first. Then it:
  - resets the terminal, which fixes garbled characters, a missing cursor or odd colors after printing a binary file;
  - clears the screen and scrollback;
  - forgets this tab's command list and their captured output.
- **Optionally,** Deep Clean also removes those commands and their saved output from History.
- **Your shell keeps running,** with its folder, variables and anything in progress.

## Sharing a tab (read-only)

- **Shell → Share This Tab (Read-Only)…** copies a link. Anyone on your network who has it can watch the tab's screen live in their browser. They can't type anything.
- **The link** has a long random secret. The page can't be embedded in other sites. Up to 20 people can watch at once.
- **When it stops:** when you stop it (click the blue "Sharing" chip), close the tab, quit, or after 2 hours.
- **Be aware** that it isn't encrypted, so use it on networks you trust. macOS may ask once whether Anser can accept incoming connections.

## Previews and hosts

- **Quick Look on hover.** Rest the mouse on a file path printed in the output, like `src/app.swift:42` from a compiler or a file `ls` listed, and a preview appears. Move away and it closes. Turn it off in Settings → Behavior.
- **SSH hosts in the sidebar**, from `~/.ssh/config` and the files it includes. Click a host to connect in a new tab. A host with a profile shows its color and badge.
- **Profiles apply as soon as you connect.** Running `ssh prod-web` colors the tab and shows the badge right away, matching the name you typed or its real host name from your ssh config, even on servers without Anser's hooks.

## Working across panes and apps

- **Quick terminal.** Settings → Behavior → Quick terminal sets a shortcut (for example ⌃`) that drops a terminal down from the top of the screen in any app. Press it again to go back to where you were. Its height is set by `quickTerminalHeight` (0.2–0.9).
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

- Anser menu → Check for Updates uses Sparkle. Builds made after `scripts/setup-updates.sh` check automatically and verify each update's signature. The switch is in Settings → Behavior. See [RELEASING.md](RELEASING.md).

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
- **Discoverable:** ⌘/ shows every shortcut, and a short welcome card appears on first launch (Help → Show Welcome Tips brings it back).
- **Command blocks:** a colored bar beside each command and its output (green ok, red failed, yellow running). Hover a block for its exit code, duration, Copy output, Copy command and Re-run.
- **⌘-click file paths** in output (`src/app.swift:42:10`, `main.go(7)`, Python tracebacks) to open them at that line in Cursor, VS Code, Zed or Sublime. Set `"openFilesWith"` in config to choose, including terminal editors like nvim.
- **Tabs show activity:** a spinner while a command runs, a red dot when one failed in the background, a blue dot when one finished. Narrow tabs get a ⌄ menu listing them all.
- **Previews in pickers:** diffs in Changed Files, output in Commands-in-this-tab, commit log plus ahead/behind in the branch switcher, folder contents in Jump to Folder.
- **Splits:** each pane gets a header (title, folder, zoom, close), the inactive pane is dimmed, and ⇧⌘↩ zooms a pane to full size and back.
- **Completion docs:** the full description of the highlighted suggestion appears beside the popup.
- **Sidebar** (⌃⌘S): git changes, recent folders, notebook and workflows, one click each.
- **Polish:** a ligatures on/off setting, recent actions first in the palette, VoiceOver labels throughout, and a status row that folds its buttons into "…" when narrow.
- **ssh:** `ssh host` from Anser brings the editor, completion and history into the remote zsh or bash. Hooks are unpacked into a temp folder for that session and deleted on logout; nothing is installed on the server. Completion skips your Mac's files while remote, and history entries are tagged `ssh://host/path`.
- **Workflows** (⌥⌘R): saved multi-step commands with `{{parameters}}`, with dropdowns where you list options. Personal ones live in `~/.config/anser/workflows/`; put them in a repo's `.anser/workflows/` to share with your team. Shell → Save Commands as Workflow… creates one from this tab.
- **Export** a tab's commands and outputs as Markdown, JSON, PDF, HTML or text (⇧⌘S), or one command's output (⌥⇧⌘S).
- **AI help (off by default):** see above.
- **Open a command's output in its own window** from its hover strip: scroll, find (⌘F), copy or export it.
- **Problem reports:** crashes, UI hangs and recent activity are logged locally in `~/Library/Logs/Anser`. Help → Report a Problem builds a report you review and copy; nothing is uploaded.
- **Find** in scrollback with ⌘F, using Ghostty's own search.
- **Commands in this tab** (⌘B): every command you ran, with exit status and duration. Jump to it, copy its output, or run it again. ⌘↑/⌘↓ jumps between prompts.
- **Safe by default:**
  - Anser asks before closing a pane, tab or the app while something is running.
  - Commands that look like they contain secrets (`*token=*`, `export *secret*` and similar) are never saved to history.
  - You can pause history per tab.
  - Flags for unknown commands are read from man pages; only well-known tools are ever run with `--help`.
- **Session restore:** windows, tabs, splits and their folders come back on relaunch.
- **Full-screen programs** (vim, less, htop, tmux…) get the whole window; the bar comes back at the prompt.
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

