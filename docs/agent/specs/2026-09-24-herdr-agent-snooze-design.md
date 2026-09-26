# herdr agent snooze — design

Date: 2026-09-24
Scope: `terminal/.config/herdr/herdr-agent-priority.sh`, `terminal/.config/herdr/config.toml`

## Problem

alt+g walks the top priority band of waiting agents. When a high-priority
session is blocked on something outside herdr — another agent's review (~5m), a
human review (30m+), an email reply (4h+) — it keeps coming up as the alt+g
target even though there is nothing to do in it yet. Demoting it is the wrong
tool: its importance has not changed, only its timing.

## Goal

Take a pane out of the alt+g queue for a chosen duration. After that it simply
counts again. No notification, no automatic resurfacing — the next alt+g after
expiry treats it like any other waiting agent.

## Non-goals

- Waking on expiry (toast, sidebar re-sort). Considered and rejected for
  simplicity; nothing runs when a snooze ends.
- Early wake when the snoozed agent goes blocked. Rejected: needs a hook, and
  the hook-free variant breaks when you snooze an already-blocked pane.
- Sidebar indication. The sidebar is unchanged.
- Surviving pane restarts with new pane ids. Pane ids are what the rank store
  already keys on; the same limits apply.

## Design

### State

`$STATE_DIR/agent-snooze` (i.e. `~/.local/state/herdr/agent-snooze`), one line
per snoozed pane: `pane_id<TAB>wake_epoch<TAB>step` (epoch in seconds, step in
minutes; see below). Separate
from the rank store so the two never interact. Written with the same
temp-file-and-`mv` pattern as `store_set`.

A pane is snoozed iff it has a line whose `wake_epoch` is greater than now.
Expired lines are inert; they are just ignored until cleaned up.

### `snooze [pane_id]` — bound to alt+z

Steps the target pane (explicit argument, else focused, via `target_pane`)
through a fixed ladder, each step measured from now:

    unsnoozed → 5m → 30m → 2h → 4h → unsnoozed

The step a pane was *set* to is stored alongside its wake time, making the
line `pane_id<TAB>wake_epoch<TAB>step` (step is the duration in minutes: 5,
30, 120, 240). Deriving the step from the remaining time instead would be
ambiguous — a half-used 30m looks like a fresh 15m.

- Snooze active: the press moves to the ladder entry after `step`; from 240
  it removes the line (off).
- No line, or expired: the press starts at 5m.

Toast on every press, via the existing `toast`, replacing the previous one:

- `Snoozed 30m` / `<title> · until 14:30`
- `Snooze off` / `<title>`

Focus does not move, so the key can be pressed repeatedly. The next alt+g
naturally goes elsewhere because this pane has left the queue.

### `queue()`

Reads the snooze file once and passes the active pane ids to jq
(`--argjson snoozed`), then filters them out alongside the existing
`working` exclusion. This is the only behavioural change to alt+g. The
"Top of the ranking" toast path is unaffected: a snoozed pane is simply not in
the band.

### Picker (`rows()`)

Snoozed panes stay in the list (the picker is "everything you have on"). Their
status column shows `zz HH:MM` (wake time, local) instead of the agent status,
dimmed. Sorting within a band puts snoozed rows last. Selecting one still jumps
to it.

### Picker keys: command mode by default, `/` to search

The picker's commands drop the alt modifier. Plain letters would otherwise be
swallowed from the search query (a title search containing p or z becomes
untypeable), so the picker gets two modes, built from fzf's own
`show-input`/`hide-input`, `enable-search`/`disable-search` and
`unbind`/`rebind` actions (fzf 0.74 here).

Command mode (the default on open; input hidden, search disabled):

| key        | action                                  |
|------------|-----------------------------------------|
| up/down    | move                                    |
| enter      | jump to the row                         |
| p          | raise one step (`up {1}`)               |
| P          | lower one step (`down {1}`)             |
| z          | step the snooze ladder (`snooze {1}`)   |
| 1-5        | set rank outright (3 = unranked)        |
| 0          | clear rank                              |
| /          | enter search mode                       |
| esc        | close the picker                        |

Search mode (after `/`; input shown, search enabled, the command keys above
unbound so every letter and digit types): enter jumps, esc clears the query and
returns to command mode (hide input, disable search, rebind, restore header).

Each action still reloads via `rows`, as the digits do today. The header shows
the key legend for the current mode (`change-header`). The old `alt-p` /
`alt-P` fzf bindings are removed. The herdr-level alt+p / alt+shift+p / alt+z
keybinds for the focused pane are unchanged.

### `stamp` (startup hook)

Also rewrites the snooze file, dropping lines whose pane no longer exists or
whose `wake_epoch` has passed, so the file cannot grow without bound.

### Keybind

`config.toml`:

    [[keys.command]]
    key = "alt+z"
    type = "shell"
    command = 'sh -c "$HOME/.config/herdr/herdr-agent-priority.sh snooze"'
    description = "Snooze agent (5m/30m/2h/4h/off)"

alt+z is currently unbound. The zoom comment names it as the fallback if
alt+f's readline cost bites; that comment is updated to say alt+z is taken by
snooze.

The header usage block in the script gains `snooze [pane_id]`.

## Error handling

- No focused agent / unknown pane: exit 0 silently, as `up`/`down` do.
- Missing or unreadable snooze file: treated as empty (created on first write,
  like the rank store).
- Malformed lines (non-numeric epoch or step): treated as not snoozed and
  dropped on the next write or `stamp`.

## Testing

Manual, against the live session (herdr has no test harness here):

1. alt+z on a waiting agent: toast shows 5m and a wake time; `list` no longer
   shows the pane; alt+g skips it.
2. Press alt+z four more times: 30m, 2h, 4h, off; file line updates each time,
   then disappears.
3. Snooze with a short epoch edited into the file (now + 20s): after it passes,
   `list` shows the pane again with no other action.
4. Picker shows `zz HH:MM` for a snoozed row, dimmed and last in its band;
   enter jumps to it.
5. Picker opens in command mode: p/P/z/1-5/0 act on the highlighted row
   without typing into anything; `/` opens search where "pz 123" types
   literally; esc returns to command mode, a second esc closes. Also record
   whether the cursor stays on the searched-for row after leaving search — if
   it does, "/ find, esc, p" is a supported flow; if not, note it in the
   script comments rather than working around it.
6. Close a snoozed pane, run `stamp`: its line is gone.
7. `sh -n` and `herdr config check` pass.
