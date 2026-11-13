<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/social/readme-banner-dark.png">
    <img alt="Anser — a fast, native macOS terminal with a real command editor" src="branding/social/readme-banner-light.png" width="800">
  </picture>
</p>

# Anser

A fast native macOS terminal built on **libghostty** (Ghostty's GPU terminal engine), with a real command editor on top.

## Why Anser

- **Helpful like Warp, fast like Ghostty, and nothing leaves your Mac.** There's no account, no cloud and no telemetry. AI help is optional and uses your own Claude key, your Copilot plan or a local model.
- **A real editor for commands:** mouse and keyboard selection, completion for git, npm, docker, kubectl and 700+ more tools, and ghost text from your history.
- **History that remembers more:** every command with its folder, branch, exit code and time, plus searchable output.
- **Git at a glance:** branch, changes, pull request checks and merge conflicts in the status row, each one click from a fix.
- **Command Notebook:** saved commands and workflows with `{{values}}`, synced through iCloud or a git repo.
- **Shells that survive:** quit, restart or update Anser and your running commands keep going. Your tabs reconnect to them.
- **Safe by default:** profiles color production tabs and ask before risky commands. Secrets stay out of history. Repo files can't run code through Anser.

See **[docs/FEATURES.md](docs/FEATURES.md)** for everything, with shortcuts. Press ⌘/ in the app for all keys.

## Install

Download the DMG, drag Anser to Applications, and open it. It updates itself (Anser menu → Check for Updates).

Or with [Homebrew](https://brew.sh):

```bash
brew install --cask nevin/tap/anser
``` Your zsh or bash history is imported on first launch, and your Ghostty theme and font are used automatically.

Coming from iTerm2 or Warp? App menu → **Import from iTerm2 or Warp…** brings over themes, font and workflows.

## Uninstall

1. **Quit Anser with ⌥ Quit** (hold Option in the Anser menu). A plain Quit keeps your shells running in the background; ⌥ Quit ends them too.
2. **Drag Anser from Applications to the Trash.**

That removes the app. Your settings and history stay on your Mac in case you come back. To remove those too, run this in any terminal:

```bash
pkill -x anser-session                                         # any shells still running in the background
rm -rf ~/.config/anser \
  ~/Library/"Application Support"/Anser \
  ~/Library/Caches/Anser ~/Library/Caches/app.anser.terminal \
  ~/Library/HTTPStorages/app.anser.terminal \
  ~/Library/Logs/Anser \
  ~/Library/"Saved Application State"/app.anser.terminal.savedState
defaults delete app.anser.terminal 2>/dev/null                 # preferences: window sizes, panels, tips
while security delete-generic-password -s Anser >/dev/null 2>&1; do :; done                     # AI keys
while security delete-generic-password -s app.anser.terminal.secret >/dev/null 2>&1; do :; done # saved secrets
```

What each one held:

| Location | What's there |
|---|---|
| `~/.config/anser` | Settings, Command Notebook, aliases, plugins, runbooks |
| `~/Library/Application Support/Anser` | Command history and saved output, saved windows and tabs, background shells |
| `~/Library/Caches/…`, `HTTPStorages/…`, `Logs/Anser` | Caches and logs, safe to delete any time |
| Preferences (`app.anser.terminal`) | Window sizes, panels, tips you've seen |
| Keychain (`Anser`, `app.anser.terminal.secret`) | Your AI API key and any secrets you saved |

If you turned on sync, Anser also wrote to the folder you picked (for example `iCloud Drive/Anser`). Delete it there if you don't need it on your other Macs. Anser never edits your `.zshrc`, `.bashrc` or shell history, so there's nothing to undo there.

## Build from source

```sh
bash scripts/build-ghostty.sh   # once: builds libghostty from upstream + patches/ (needs ~5 GB, a few minutes)
bash scripts/build-app.sh       # builds build/Anser.app
open build/Anser.app
```

- **Unit tests:** `swift test`
- **Live end-to-end check:** `bash scripts/build-app.sh debug && bash scripts/selftest.sh`. It drives the real app, saves UI snapshots to `build/selftest/`, and writes results to `build/selftest/results.txt`.
- **Releasing** (signing, notarization, update feed): [docs/RELEASING.md](docs/RELEASING.md).

## How it works

- `Sources/AnserCore`: pure Swift (lexer, fuzzy matcher, SQLite history, completion engine, specs, config). Unit tested.
- `Sources/Anser`: the AppKit app (Ghostty surface view, command editor, popup, panes, splits, pickers).
- `Resources/shell`: zsh/bash hooks. They send prompt and command events to the app through a private FIFO, using only shell builtins. They also load Ghostty's own integration, which provides the prompt marks.
- `patches/ghostty-anser.patch`: two small additions to libghostty, `ghostty_surface_read_command_output` (exact output copying) and `ghostty_surface_prompt_marks` (command block positions).

Shell support: zsh and bash get the full editor, in emacs or vi mode, locally and over ssh. fish has hooks too (not yet tested). Other shells (fish, nushell) still work as a normal Ghostty terminal; the bar says integration isn't active.

## License

Anser is released under the [MIT License](LICENSE). Copyright (c) 2026 Nevin Paul.

It builds on other MIT-licensed projects, whose copyright notices apply to their parts:
[Ghostty](https://github.com/ghostty-org/ghostty) (the terminal engine),
[Sparkle](https://github.com/sparkle-project/Sparkle) (updates) and
[Fig's autocomplete specs](https://github.com/withfig/autocomplete) (completions, when imported).
