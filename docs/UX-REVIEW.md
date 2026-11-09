# UX review

## Product review (November 2026)

The review covers the menus, the windows, Settings, the sidebar, the status row, command blocks, onboarding and the feature list in [FEATURES.md](FEATURES.md). It's based on the code and the docs; no user testing was done.

### In short

Anser does a lot, and does each thing carefully: forms check as you type, empty lists explain themselves, risky actions ask first, and status colors have one meaning each. The main problem is **sprawl**. About 150 features have each been given their own entry point, window, shortcut or setting. Users run into overlapping concepts (Notebook, Workflows, Runbooks, Snippets, Aliases), eight ways to search, around 20 separate windows, and shortcuts that are hard to remember. What's needed now is fewer, stronger surfaces, more than new features.

### Top five recommendations

| # | Change | Why | Effort |
|---|---|---|---|
| 1 | **One search.** Merge History search, Search Output, Find in All Tabs, Commands in This Tab and Library search into one ⌘R window with scopes (This tab · All tabs · History · Output · Saved). Keep ⌘F for find on screen and ⌃R for inline history. | 8 search surfaces today; people have to know which one holds what they want | L |
| 2 | **Notebook and Workflows become one thing.** A notebook entry can already have `{{values}}`; a workflow is just an entry with several steps. Keep Runbooks separate, since they're documents. | Two names for "saved command with values" means users have to choose, and look in two places | M |
| 3 | **Fewer windows.** The Library becomes the home for managing things: Notebook editing, Aliases, Edit History and Secrets open as its sections instead of their own windows. | About 20 window types, many of them floating, so they get lost behind the terminal | L |
| 4 | **Settings by purpose.** Split Behavior (19 switches) into Notifications, Privacy & History, Sessions, Suggestions. Make the config-only options reachable too (`showCloudContext`, `compactPrompt`, `openFilesWith`, `quickTerminalHeight`). | Behavior is a catch-all, and some options exist only in JSON | S–M |
| 5 | **A shortcut scheme.** One modifier per family: ⌘ core, ⇧⌘ the same thing for "all/bigger", ⌥⌘ saved things, ⌃⌘ windows/panels. Then reassign the outliers (see below). | ⌘R, ⇧⌘R, ⌥⌘R and ⌃⌘R are four unrelated things; the L family is filter, log viewer, commit history and blame | M |

### Findings

Severity: **High** = blocks or confuses most users, **Medium** = slows people down, **Low** = polish.

#### Information architecture

- **High: Overlapping saved concepts.** Notebook, Workflows, Runbooks, Snippets (old, moved into Notebook), Aliases and Workspaces are all "things I saved". The Tools menu has 7 entries for them (Library, Saved Panel, Save to Notebook, Edit Notebook, Workflows, Runbooks, Aliases), and a Create submenu besides. → Recommendation 2, then cut the Tools menu down to Library, Saved Panel and Save Command.
- **High: Search is spread out.** ⌘F, ⇧⌘F, ⌘R, ⌃R, ⌥⇧⌘F, ⌘B, ⌘J, Switch to Tab, Library search and the History Editor search all search something. → Recommendation 1.
- **Medium: The Notebook has three editors.** The Saved panel, the Library's Notebook section and the Command Notebook window (Edit Notebook…). → Edit in the Library; the Saved panel is for using things.
- **Medium: The Shell menu mixes levels.** Tabs and splits sit next to Output, Run and Watch, Remote and Record submenus. Recording and sharing aren't shell things. → Move Record and Share into an **Output** or **Share** menu and leave Shell for tabs, panes and running.

#### Discoverability and learning

- **Medium: Five kinds of onboarding.** A welcome card, a 5-page tour, What's New, one-time tips and the ⌘/ sheet, and the Help menu shows four of them. → Merge Welcome Tips into the tour, so Help has Tour, What's New and Shortcuts.
- **Medium: The hover strip has 10 icon-only buttons.** Share (link) and Export (square with arrow) look alike, and the ✨ shows even on commands that worked. → Show 4 (Run again, Copy output, Explain only on failure, …), with the rest under a "…" that opens the same menu as right-click.
- **Low: The palette is the real index.** The palette finds actions by purpose ("typo" → Edit History), which is excellent. → Make ⇧⌘P the "how do I…" answer in the tour, and mention it in empty states.

#### Consistency

- **Medium: Shortcut collisions and clutter.**
  - ⌥⌘D (select next match) is macOS's Dock hiding shortcut, so it probably never reaches Anser. Needs checking; ⌘D-style alternatives are taken, so ⌃⌘D or ⌥⌘G could work.
  - Families that don't share a meaning: R (history, rerun, workflows, record), L (filter, log viewer, commit history, blame), S (sidebar, save to notebook, export).
- **Medium: Select vs Show.** In the History Editor, the toolbar's "Select Mistakes" selects rows while the side panel's "Show Mistakes" filters the list. That's two verbs for nearly the same goal, side by side. → Keep the filter (Show), and make selecting all a second step (⌘A).
- **Low: Words.** "Saved Panel", "Library", "Notebook" and "Saved commands" all name overlapping things; "Deep Clean" vs "Clear"; "Edit History" (tool) vs "Search History" (Go). Write a short glossary and use it everywhere.

#### Feedback and attention

- **Medium: The status row can bury important things.** Up to 4 chips plus "+N" is a good cap, but chips come from about 15 sources (servers, cloud context, ssh, env, alias tips, fixes, failed tests, watching, REC, sharing, all panes, PR, conflicts…). → Rank risk first: REC, Sharing and "all panes" (things that are on and affect privacy or input) should never go into +N.
- **Medium: Notifications come from 4+ places** (long commands, waiting for input, watches, ssh). Each has its own switch in different places. → One Notifications section in Settings, with one row per kind.
- **Low: Suggestions fade after 20 seconds.** That's good for calm, but timed content can be missed by people who read slowly. → Respect "Reduce motion", and keep missed suggestions under +N.

#### Accessibility

- **Low:** VoiceOver labels and colors-plus-text chips are in good shape. Check that the activity chart and bars in the History Editor have readable summaries (the bars do; the chart doesn't), and that all panels follow the system text size.

### Quick wins (an hour or less each)

1. The Go menu has two separators in a row (`AppDelegate.swift`, after Jump to Folder).
2. FEATURES.md still says the sidebar holds "notebook and workflows" (in Everything else → Sidebar).
3. Rename History Editor's "Select Mistakes" or drop it in favor of the Show filter.
4. Give the History Editor's activity chart an accessibility label ("312 runs in the last 30 days, busiest Tuesday").
5. Hide ✨ Explain on the hover strip for commands that worked.
6. Check ⌥⌘D, and rebind it if macOS takes it.
7. Merge Help → Show Welcome Tips into Take the Tour.

### What was done (November 2026)

All of the above was implemented:

- **Quick wins:** the Go menu separator is fixed, and the stale sidebar line in FEATURES.md is updated. The History Editor's toolbar no longer has Select Mistakes or Select Basic; the Show filters in its side panel come with a **Select All** for the filtered list. The activity chart has a VoiceOver summary. Next match in the editor is ⌥⌘G (⌥⌘D still works where macOS doesn't take it). Help → Show Welcome Tips is gone, and the welcome card has a Take the Tour button. ✨ Explain was already hidden on commands that worked.
- **One search:** ⌘R opens Search with seven scopes (All, This folder, This tab, Failed, Output, All tabs, Saved). ⌘B, ⇧⌘F, ⌥⇧⌘F and Go → Search Saved Commands open it on their scope. The separate Commands in This Tab and Find in All Tabs windows are gone.
- **Notebook and Workflows merged:** workflows show as Notebook groups in the Saved panel, the Library (no separate Workflows section) and Search → Saved. Tools → Run from Notebook (⌥⌘R) lists notebook entries and workflows together. The files stay where they were, so repos keep sharing `.anser/workflows`.
- **Fewer windows:** the Notebook, Aliases, History and Secrets editors open as tabs of the Library window (Tools → Manage). The Notebook and Secrets windows were floating panels before; now they're normal windows.
- **Settings by purpose:** Behavior is now Notifications, Suggestions & Helpers, Privacy & History, and Sessions & Windows. New controls cover the cloud context chip, the editor for ⌘-clicked files and the quick terminal height. `compactPrompt` was already covered by the Shell prompt menu.
- **Shortcut scheme:** families are ⌘ everyday, ⇧⌘ the bigger version and git, ⌥⌘ saved things, ⌃⌘ windows and panels. The ⌘/ sheet is grouped that way. Filter Output moved to ⌃⌘O; ⌥⌘L keeps working through a hidden menu item.
- **Menus:** a new **Output** menu holds filter, log viewer, compare, table/JSON, export, share and record. Shell is for tabs, panes and running. Tools is Library, Saved Panel, Save, Run from Notebook, Runbooks, Manage ▸, Create ▸, Servers ▸ and AI.
- **Status row:** REC, Sharing and "all panes" never fold into +N. Suggestions don't fade with Reduce Motion or Increase Contrast.
- **Hover strip:** Run again, Copy output, Copy command, Save to Notebook, ✨ (failed only) and **…**, which opens the full right-click menu.
- **Glossary** (the words used everywhere now): **Notebook**, your saved commands, including workflows (entries with several steps). **Runbook**, a Markdown checklist. **Saved panel**, the right-hand panel for using them. **Library**, the window for managing everything. **Search**, the one ⌘R window.

Not done: the usability test with 3–5 users. It's still worth running, especially on Search and on the Library tabs.

### Suggested order (original plan)

1. **Quick wins** above.
2. **Settings by purpose** and **one Notifications section** (small, low risk).
3. **Shortcut scheme**, with old shortcuts kept working for one release and listed in What's New.
4. **Notebook + Workflows merged**, with existing workflow files read as notebook entries.
5. **One search** and **the Library as the manager** (the largest; do these with a short usability test of 3–5 users first).

---

## Side panels and saved commands (November 2026)

### What we found

1. **Notebook was in two panels at once.** The left sidebar had Notebook and Workflows sections, and the right-hand panel (⌥⌘N) showed the same Notebook and Workflows. With both open, the same commands appeared on both sides of the terminal.
2. **Saved things were spread out.** Runbooks were only in the left sidebar, workflows were in both panels, and the Library window had all of them again. There was no clear answer to "where do I find my saved commands?"
3. **The panels had no clear job.** The left sidebar mixed live information (git, servers, containers) with saved lists, so it grew long and the live sections got pushed down.
4. **Names didn't match.** The panel was called "Notebook", but it also held workflows. The menu said "Command Notebook", and the editor window had the same name.
5. **The History Editor wasted space.** Below the list, the details box used only its left side, and with nothing selected it showed one gray line.

### What changed

| Place | Its one job | Holds |
|---|---|---|
| Left sidebar (⌃⌘S) | Where you are, what's running | Git, failed tests, servers, tasks, containers, pods, watches, tunnels, folders, SSH hosts |
| Saved panel, right (⌥⌘N) | Things you saved to run again | Notebook, workflows, runbooks, with one search |
| Library window (⌥⌘O) | Manage everything | Also aliases, history, recordings, watches |
| Command Notebook window | Edit the notebook | Groups, titles, notes |

- The Notebook, Workflows and Runbooks sections left the sidebar. While the Saved panel is closed, the sidebar ends with one "Saved commands · N" link that opens it, so saved commands stay discoverable.
- The right panel is now called **Saved** in its header, menu (Tools → Saved Panel), palette, tooltip and Help. Runbooks were added to it, along with a Library button.
- The History Editor got a side panel: an overview when nothing is selected, a track record and actions for one command, and a breakdown with bulk actions for several.

### Left for later

- The Library window's sidebar still lists Notebook, Workflows and Runbooks. That's on purpose, since it is the manager, but it could open the Saved panel for quick use.
- The status-row "+N" menu and the right-click command menu both offer "Save to Notebook". That's fine: they're actions, not lists.
