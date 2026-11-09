# Anser plugins

A plugin is a folder in `~/.config/anser/plugins` with a `plugin.json`. It can add:

- **Chips** in the status row (a Node version, how old the branch is, open tickets).
- **Actions** in the command palette (⇧⌘P).
- **Sidebar sections** (recent deploys, todos, anything with a list).
- **Hooks** that run after commands (log long builds, ping a chat when tests fail).

A plugin does nothing until you turn it on in **Settings → Plugins**. That page also makes an example to start from (**New Example Plugin**), adds ready-made ones (**Add Starter Plugin**: Node version, Python environment, pull requests, TODO count, long command log) and lists any plugin.json it can't read.

## plugin.json

```json
{
  "name": "Node",
  "description": "Node version in JavaScript projects, and a few npm helpers",
  "chips": [
    { "id": "version", "script": "node --version", "when": ["package.json"] }
  ],
  "actions": [
    { "title": "npm: check for outdated packages", "run": "npm outdated" },
    { "title": "npm: count dependencies", "script": "./count-deps.sh" }
  ],
  "sidebar": [
    { "title": "Scripts", "script": "./scripts.sh", "when": ["package.json"] }
  ],
  "hooks": { "commandFinished": "./notify.sh", "minSeconds": 30, "onlyFailures": true }
}
```

| Field | What it does |
|---|---|
| `chips[].script` | Runs after each command in that pane. Prints the chip (see below). Empty output hides it. |
| `chips[].interval` | Also refresh every N seconds (10 at least), only for the pane in front while Anser is active. |
| `chips[].when` / `sidebar[].when` | Only in folders that contain (or sit inside a folder that contains) one of these files. |
| `actions[].run` | A command run in the pane, like a saved command (profiles that ask before running still ask). |
| `actions[].script` | Runs in the background; a short result shows briefly, a long one opens in a window. |
| `sidebar[].script` | Prints rows for a sidebar section. |
| `hooks.commandFinished` | Runs after commands; `minSeconds` and `onlyFailures` narrow it down. |
| `settings` | Values you set in Settings → Plugins → Settings… (see below). |

`script` is a command line (run with `/bin/sh -c`), or `./file` for an executable in the plugin folder.

## Settings

A plugin can ask for values, like a limit or an API token:

```json
"settings": [
  { "key": "limit", "title": "How many to show", "default": "10" },
  { "key": "token", "title": "API token", "secret": true }
]
```

Scripts read them as `ANSER_SETTING_LIMIT` and `ANSER_SETTING_TOKEN`. Normal values are kept in config.json (`pluginSettings`); `secret` ones in your login Keychain, never in a file.

## Plugins that come with a repo

A repo can ship plugins in `.anser/plugins/<name>/plugin.json`, so everyone on the team gets the same chips, actions and sidebar sections. They don't need turning on in Settings, but they never run until you trust them: in that repo a **“1 project plugin”** chip appears, and clicking it shows exactly what each one runs. **Trust & Turn On** remembers the plugin's files; if anyone changes them (or adds a file), Anser asks again.

## What scripts print

A **chip** is the first line of output, or JSON:

```json
{ "text": "3 todos", "color": "yellow", "tooltip": "TODOs in this folder", "run": "rg -n TODO" }
```

`run` runs a command when you click the chip; `open` opens a web link or a file instead. Colors: red, orange, yellow, green, blue, purple, teal.

**Sidebar rows** are lines of `text<TAB>detail<TAB>command`, or a JSON array of `{ "text", "detail", "color", "run", "open" }`.

## What scripts get

Scripts run in the pane's folder, with the shell's `PATH`, and these variables:

| Variable | Value |
|---|---|
| `ANSER_CWD` | The pane's folder |
| `ANSER_BRANCH` | The git branch, if any |
| `ANSER_LAST_COMMAND`, `ANSER_LAST_EXIT` | The last command in the pane and its exit code |
| `ANSER_PLUGIN_DIR` | The plugin's own folder (for its files and logs) |
| `ANSER_SESSION` | An id for the pane's shell |
| `ANSER_COMMAND`, `ANSER_EXIT`, `ANSER_DURATION` | In `commandFinished` hooks: the command that just finished |
| `ANSER_SETTING_<KEY>` | The plugin's settings |
| `VIRTUAL_ENV` | The shell's active Python virtualenv, if any |

## Limits

- Each script gets 5 seconds; output past 64 KB is cut off.
- Plugins only run for local shells, not inside ssh sessions.
- Git commands in scripts run with repository-supplied programs turned off (like Anser's own git checks).
- Links a plugin opens can be web pages or files; apps and scripts are shown in Finder instead of opened.
- Plugins run with your permissions. Turn on only the ones you wrote or trust.
