# herdr agent priority

Rank the agents that are waiting on you from 1 to 5, and work down from the top.

Built because a fleet of thirty agents turns the sidebar into a treadmill: it
tells you *that* several sessions want you, never *which* to do first, so the
day goes to whoever happened to finish last. A number you set once, when the
session starts, lets the work be chosen instead of serviced. Priority 1 work
never getting reached is the intent, not a bug — it is the cue to close it.

Everything here runs on stock herdr APIs — no fork is needed to build it. It
does lean on one fork-only setting to stay *accurate*, though: see the note at
the end of "What alt+g does".

## Keys

The prefix is `alt+space`.

| Key | Does |
| --- | --- |
| `alt+p` | Raise the focused session's rank one step. |
| `alt+shift+p` | Lower it one step. |
| `prefix+p` | Open the ranked picker. |
| `alt+g` | Go to the top of the ranking, cycling within the top band. |
| `prefix+a` | Unrelated older sweep: jump to whoever is blocked, rank ignored. |

Nudging one session is done by reflex while reading it, so it keeps the cheap
key. Opening a whole view is deliberate, so it sits on the prefix layer.

## The scale

Five is most important, one is least, and **three means unranked**. Raising and
lowering step through the range and stop at the ends; landing back on three
removes the rank rather than writing a "P3" label, because unset already sorts
as three and putting a meaningless number on thirty untriaged rows only adds
noise.

Rank changes announce themselves with a desktop notification naming the new
rank and the session, so you do not have to go and read the sidebar. Rapid
changes replace that notification in place rather than stacking.

## The picker

An `fzf` list inside a herdr popup, showing every agent in the same order as the
sidebar. Type to filter on the session title.

| Key | Does |
| --- | --- |
| `enter` | Jump to the highlighted session. |
| `1`–`5` | Rank it outright. The list redraws and the row moves. |
| `3` | Same thing: unranked. |
| `alt+p`, `alt+shift+p` | Nudge it up or down, same as outside the picker. |
| `esc` | Close. |

## What alt+g does

It goes to the **top band**: every waiting agent sharing the highest rank
present. Three priority-5 sessions means it walks those three and wraps. It
will not drop you onto a 4 just because you pressed again, because pressing
past the thing you called most important is how a ranking rots into a to-do
list.

When the band holds exactly one session and you are already on it, it says so
instead of moving. Answering a blocked agent makes it start working, and
working agents are not in the queue, so it steps aside on its own.

To go somewhere else deliberately, use the picker rather than demoting. "Not
right now" is a different statement from "less important", and demoting to get
past something turns the rank into a schedule within a week.

Only `blocked` and `done` agents are candidates. Working agents want nothing,
and idle ones have been dealt with. Within a rank the order is blocked first,
then longest-waiting, which is deterministic so the top does not wander.

**This is why the fork still earns its keep.** `ui.done_acknowledgement =
"input"` is a fork-only setting that keeps a finished session marked `done`
until you actually type into it. On stock herdr, merely focusing a pane
acknowledges it and flips it to `idle` — which would mean `alt+g` takes you to
the top of the band and, by that very act, drops it out of the queue. Holding
at the top would collapse: every press would land somewhere new, and the
sessions you were trying not to lose track of would quietly leave the list.
Going back to the packaged binary means giving that up, or finding another way
to keep `done` sticky.

## How it is wired

`herdr-agent-priority.sh` is the whole feature. The `agent-priority` plugin
exists only to run it at the right moments.

| Path | Holds |
| --- | --- |
| `~/.local/state/herdr/agent-priority` | The ranks. This is the source of truth. |
| `~/.local/state/herdr/agent-priority.log` | Every invocation, for when a key looks dead. |
| `~/.local/state/herdr/agent-priority.selection` | The picker handing its choice back. |
| `~/.local/state/herdr/agent-priority.notify-id` | The toast being replaced. |

Two pane metadata tokens carry the rank into the UI:

- `$pri` is the visible label, set only on sessions you have actually ranked,
  and referenced by `[ui.sidebar.agents]` in `config.toml`.
- `$prisort` is on every agent, defaults to 3, and is referenced by nothing.
  The sidebar sort is a string comparison over a token, so without a value on
  every row the unranked ones sink below a deliberate "1", which is backwards.

The sidebar order itself comes from herdr's declarative agent view
(`agent.view.set`), which accepts a metadata token as a sort key. Setting a
view *with a label* makes the client take its row order from the server and
ignore `ui.agent_panel_sort` entirely. There is no CLI verb for this, so the
script speaks to the socket directly. `ui.agent_panel_sort = "priority"` in
`config.toml` is therefore inert, and is kept only as the fallback if the view
is ever cleared.

Subcommands, if you need them by hand: `up`, `down`, `set N`, `clear`, `goto`,
`open`, `pick`, `rows`, `stamp`, `view`, `list`. `list` prints the queue that
`alt+g` walks, in order, without moving anything.

## When something looks dead

Read `~/.local/state/herdr/agent-priority.log` first. Keybind commands are
spawned by the server with no terminal attached, so a failure is otherwise
completely silent — a missing symlink once hid there for a day. A line per
invocation means the key is reaching herdr and the problem is downstream.

Scripts are read fresh on each keypress, so editing one needs no reload.
Changing `config.toml` needs `herdr server reload-config`, which applies
keybinds live. Changing the plugin manifest needs `herdr plugin link` again.

## herdr behaviour worth knowing

Four things that cost real time to find, all verified on 0.8.x:

- **`herdr agent focus` does not move the client.** `agent.focus` is not in the
  server's client-shell method allowlist, so it updates server state and the
  attached client overwrites it a second later. It reads back correct
  immediately, which is what makes it so convincing. `workspace.focus` and
  `tab.focus` *are* routed to the client, so the three together are what
  actually move the view.
- **Metadata tokens do not survive a restart.** Session restore rebuilds them
  empty, which is why the ranks live in a file and the plugin re-stamps them
  from a startup hook.
- **`herdr notification show` does nothing under foot.** It reports
  `{"shown": true}` regardless. Its terminal backend only recognises ghostty,
  iTerm, kitty and wezterm. `notify-send` talks to whatever owns the
  notification bus, which under Omarchy 4 is quickshell. The same flaw means
  `[ui.toast] delivery = "system"` has been dead since the move to foot.
- **Focusing from inside a popup does not stick.** The call succeeds and the
  session restores the previous focus as the popup closes. Hence the split
  between `pick`, which runs in the popup and writes its choice to a file, and
  `open`, which runs from the keybind and does the focusing afterwards.

And one trap that is not herdr's fault: a client and server running *different
builds of the same version string* behave strangely with no warning. Compare
`/proc/<pid>/exe` against the binary on disk.
