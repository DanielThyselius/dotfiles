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
minutes; see below). Separate from the rank store so the two never interact.
Written with the same temp-file-and-`mv` pattern as `store_set`.

### Locking

Rename-into-place prevents torn reads but not lost updates: each keypress is a
separate process, each spends tens of milliseconds in `herdr agent list` before
writing, so two quick presses can both read "unsnoozed" and both write 5m, or
one pane's write can drop another pane's change. Repeated presses are the
intended interaction, so this has to hold.

Every read-modify-write of either store takes one exclusive lock,
`$STATE_DIR/agent-priority.lock`, via `flock` (util-linux). The critical section
is: read the line, compute the next value (ladder step or rank step), write the
file. The herdr metadata stamp, the toast and any other API calls happen outside
it, so a slow API call never holds up the next press. `stamp`'s cleanup of both
files runs under the same lock.

This also fixes the existing rank path: `up`/`down` have the same unlocked
read-then-write today, and a quick double alt+p can currently land one step.

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

### Picker keys: always searching, commands on alt

Typing always filters; every command is an alt chord, so no letter or digit is
ever taken from the query. The query survives each action's reload, which is
what makes a chained flow work:

    prefix+p → "herdr" → alt+z → ctrl+backspace → "smarticipate re"
             → alt+shift+p → backspace ×2 → "feat" → alt+5

| key            | action                                     |
|----------------|--------------------------------------------|
| type           | filter                                     |
| up/down        | move                                       |
| enter          | jump to the row                            |
| alt+p          | raise one step (`up {1}`)                  |
| alt+shift+p    | lower one step (`down {1}`)                |
| alt+z          | step the snooze ladder (`snooze {1}`)      |
| alt+1 … alt+5  | set rank outright (alt+3 = unranked)       |
| ctrl+backspace | delete the previous word                   |
| esc            | close                                      |

- The bare `1`-`5` and `0` bindings are removed (digits type into the query),
  and there is no separate clear key: alt+3 is unranked, as 3 is everywhere.
- `ctrl-bspace` is bound to `backward-kill-word`; fzf's default for it deletes a
  single character.
- `--track --id-nth 1` keeps the cursor on the same pane id across reloads.
  Without it a re-rank re-sorts the list under the cursor and a second
  alt+shift+p would hit a different row.
- Each action still reloads via `rows`. The header legend is updated to match.

alt+p, alt+shift+p and alt+z mean the same thing outside the picker (focused
pane) and inside it (highlighted row). alt+1-5 do not: outside the picker they
are herdr's switch_tab, so setting a rank outright by number is picker-only.

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

- No focused agent: exit 0 silently, as `up`/`down` do.
- Explicit pane id: validated against `herdr agent list` before any state is
  written (`target_pane` returns an explicit id unchecked today). An id that is
  not a live agent exits 0 without writing. The validation reuses the list call
  already needed for the toast title, so it costs nothing extra.
- Missing or unreadable snooze file: treated as empty (created on first write,
  like the rank store).
- Malformed lines — non-numeric epoch, or a step outside {5, 30, 120, 240} —
  are treated as not snoozed (the next press starts at 5m) and dropped on the
  next write or `stamp`. Without the step check an entry with step 15 would
  have no defined next rung.

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
5. In the picker: alt+p / alt+shift+p / alt+z / alt+1-5 act on the
   highlighted row and keep the query; the cursor stays on the same pane after
   the reload re-sorts; "pz 123" types literally; ctrl+backspace deletes a
   word. Confirm alt+1-5 reach the popup rather than being taken by herdr's
   switch_tab binding.
6. Close a snoozed pane, run `stamp`: its line is gone.
7. Rapid presses: run `snooze <pane> & snooze <pane> & snooze <pane> & wait`
   and confirm the step is 2h (three rungs), not 5m; same with three
   concurrent `up` from unranked landing on P5. Also snooze two different panes
   concurrently and confirm both lines survive.
8. `snooze <bogus-id>` and a line with step 15 edited into the file: nothing
   written for the former; the latter behaves as unsnoozed.
9. `sh -n` and `herdr config check` pass.
