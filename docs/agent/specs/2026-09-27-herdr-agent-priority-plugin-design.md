# herdr agent-priority: sidebar snooze label + shareable plugin — design

Date: 2026-09-27
Builds on: `2026-09-24-herdr-agent-snooze-design.md` (snooze, lock, picker keys)
Scope: part 1 in `~/dotfiles/terminal/.config/herdr/`; part 2 moves the feature
to a new public repo, `Mindful-Stack/herdr-agent-priority`.

Two parts, done in order. Part 1 is useful on its own and changes the script in
place; part 2 relocates everything, so it goes last.

---

## Part 1 — show snoozes in the sidebar

### Problem

A snooze is only visible inside the picker. In the sidebar, where the eyes
usually are, a snoozed pane looks like any other, so it is easy to forget what
was set aside and until when.

### Goal

A snoozed agent row shows `zz 14:30` (its wake time) next to its rank label, and
the label disappears by itself at the wake time. No background process.

### Non-goals

- Time remaining (`zz 25m`). Considered and rejected: it goes stale unless
  something rewrites it every minute, and the choice was between a per-snooze
  updater process and a label that lies between keypresses. The wake time never
  needs rewriting.
- Any change to what alt+g, the picker or the snooze store do.

### Mechanism

`herdr pane report-metadata` takes `--ttl-ms <N>` (1 ms – 24 h): the reported
metadata expires on its own. Verified on herdr 0.8.2 on 2026-09-26: a token
reported with `--ttl-ms 4000` under source `snooze-probe` was present
immediately, gone after 5 s, and tokens from other sources on the same pane
(`pri`, `prisort`, `idx`) were untouched.

So the snooze label is its own metadata report:

- **Source:** `agent-snooze` — distinct from the rank source `agent-priority`,
  so the TTL can never expire the rank tokens.
- **Token:** `snz`, value `zz HH:MM` (local time of the wake).
- **TTL:** `(wake_epoch - now) * 1000`, i.e. it expires exactly at the wake.

### Writes

| When | What |
| --- | --- |
| `snooze` sets a rung | Report `snz=zz HH:MM` with the TTL for the new wake. Replaces any earlier report from the same source. |
| `snooze` reaches off | Report `--clear-token snz` under source `agent-snooze`. |
| `stamp` (startup / agent detected) | For every active snooze of a live pane, re-report `snz` with the *remaining* TTL. Needed because herdr's restore rebuilds metadata tokens empty. Runs inside `prune`, after the snooze store rewrite, under the same lock. |

The label write is metadata, like the rank stamp, so for the same reason (the
display must follow write order) it runs **inside** the snooze critical section:
`snooze_step` stamps after `mv`. A failed stamp is logged, not fatal — the store
is the truth; the label is a projection of it, restored by the next `stamp`.

A snooze that expires needs nothing: herdr drops the token at the TTL, and the
store line is already inert.

### Display

Both sidebar row templates in `config.toml` gain `$snz` right after `$pri`:

```toml
[ui.sidebar.agents]
rows = [["state_icon", "$idx", "$pri", "$snz", "workspace", "tab"], ["agent"]]

[ui.sidebar.agents.rows_by_agent]
claude = [
  ["state_icon", "$idx", "$pri", "$snz", { token = "workspace", dim = true }],
  ["terminal_title_stripped"],
]
```

Dimmed as `{ token = "$snz", dim = true }` if herdr accepts `dim` on a custom
`$token` (check with `herdr config check`; if it reports the key unknown or
ignored, fall back to the bare `"$snz"`). An unset token renders nothing, as an
unranked `$pri` does today.

### Testing

Offline, via the existing harness (the stub `herdr` appends every
`report-metadata` call to `metadata.log`):

1. `snooze w1:p1` → metadata.log has a `--source agent-snooze` call for w1:p1
   with `--token snz=zz HH:MM` (HH:MM = local wake time) and a `--ttl-ms` within
   1 s of 300000.
2. Four more presses → the last call for w1:p1 is `--clear-token snz`.
3. `stamp` with an active snooze (wake now+600) on a live pane → a `snz` report
   with `--ttl-ms` ≈ 600000; no report for an expired or gone-pane snooze.
4. `stamp` with the pane-list failure modes → no `snz` reports (existing guard).
5. Rank stamps still use `--source agent-priority` and never carry `--ttl-ms`.

Live: snooze a pane, see `zz HH:MM` in the sidebar; press through to off, label
gone; snooze 5m, label gone at the wake time with nothing pressed.

---

## Part 2 — publish as a herdr plugin

### Goal

Anyone on herdr ≥ 0.8.2 can install the feature with

    herdr plugin install Mindful-Stack/herdr-agent-priority

add a few lines to `config.toml`, and have ranks, snooze, alt+g and the picker
working — without copying files into `~/.config/herdr` or editing paths.

### Non-goals

- Migrating other people's data from anywhere (there is none).
- Automatic migration code for the author's own state: done once, by hand.
- Setting keybinds for the user. A plugin cannot write `config.toml`; the README
  supplies the snippet.
- Renaming. The plugin id stays `agent-priority`, as do the metadata sources
  (`agent-priority`, `agent-snooze`) and token names (`pri`, `prisort`, `snz`),
  so existing ranks keep working.

### herdr plugin facts this relies on

From herdr's own docs for v0.8.2 (`docs/.../plugins.mdx`, fetched 2026-09-27)
and checks on the installed 0.8.2:

- Manifest `herdr-plugin.toml` at the repo root (or a subdirectory). Required:
  `id`, `name`, `version`, `min_herdr_version`. Sections used here:
  `[[startup]]`, `[[events]]`, `[[actions]]` (`id`, `title`, `contexts`,
  `command`), `[[panes]]`.
- `herdr plugin install owner/repo[/subdir]` clones with git into
  herdr-managed plugin data and registers it. `herdr plugin link <dir>`
  registers a local working tree without moving it.
- Plugin commands get `HERDR_PLUGIN_ROOT` (the installed or linked directory),
  `HERDR_PLUGIN_STATE_DIR` (local runtime state), `HERDR_PLUGIN_CONFIG_DIR`, and
  for actions `HERDR_PLUGIN_ACTION_ID` and `HERDR_PLUGIN_CONTEXT_JSON`.
- A keybind invokes a plugin action with
  `type = "plugin_action"`, `command = "<plugin-id>.<action-id>"`, e.g.
  `command = "agent-priority.snooze"`. (`herdr config check` accepts any
  string there, so the format comes from the docs, not from validation —
  verify it live before the README promises it.)

### Repository layout

```
herdr-agent-priority/
  herdr-plugin.toml        manifest: startup, events, actions, picker pane
  agent-priority.sh        the script (was herdr-agent-priority.sh)
  tests/
    test.sh                offline suite (moved from dotfiles)
    agents.json
    bin/herdr, bin/notify-send
  README.md                what it is, install, config snippets, keys
  LICENSE                  MIT
  .github/workflows/test.yml
```

Checked out at `~/Source/herdr-agent-priority`. The initial commit imports the
current files; the dotfiles history is not carried over.

### Manifest

`[[startup]]` and `[[events]] on = "pane.agent_detected"` run `stamp`, as now.
`[[panes]] id = "picker"` stays a popup. New `[[actions]]`, one per keyboard
entry point:

| action id | runs | bound by the README snippet to |
| --- | --- | --- |
| `up` | `up` | alt+p |
| `down` | `down` | alt+shift+p |
| `snooze` | `snooze` | alt+z |
| `goto` | `goto` | alt+g |
| `open` | `open` | prefix+p |

Every command is `["sh", "-c", "exec \"$HERDR_PLUGIN_ROOT/agent-priority.sh\" <sub>"]`.

### Script changes

- **Self location.** `SELF` (used by the picker's reload binds) becomes
  `${HERDR_PLUGIN_ROOT:-$(dirname "$0")}/agent-priority.sh` instead of
  `$HOME/.config/herdr/herdr-agent-priority.sh`.
- **State location.** `STATE_DIR` becomes `${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr/agent-priority}`.
  All state files keep their names. A hand-run `agent-priority.sh list` in a
  plain shell has no `HERDR_PLUGIN_STATE_DIR` and would read the fallback, not
  the plugin's state: the README says to run it as
  `HERDR_PLUGIN_STATE_DIR=<dir> agent-priority.sh list`, with `<dir>` whatever
  herdr reports (find how during implementation — `herdr plugin config-dir`
  exists; check whether a state-dir equivalent does, else print the path to the
  log on every run). The author moves the existing files from
  `~/.local/state/herdr/agent-priority*` and `agent-snooze` into the plugin
  state dir once, by hand, before switching over.
- **Socket.** `set_view` connects to `$HERDR_SOCKET_PATH` when set, else the
  current default path.
- **Key hints.** `keybind_for <sub>` also matches `[[keys.command]]` entries with
  `type = "plugin_action"` and `command = "agent-priority.<sub>"`, alongside the
  existing shell-command match (so the author's config works during the switch).
- **Popup open.** `open` already runs `herdr plugin pane open --plugin agent-priority --entrypoint picker`; unchanged.

### README

Sections: what it does (rank, alt+g, picker, snooze — short, with the "why"
from the current README); install (`herdr plugin install …`); the
`config.toml` snippet with the five `plugin_action` keybinds and the two
sidebar row templates (`$pri`, `$snz`) and `agent_panel_sort`; keys table;
requirements (`jq`, `fzf`, `python3`, util-linux `flock`, `notify-send`
optional); state files; troubleshooting (the log file). Notes the known
constraint that alt+shift+p needs the kitty keyboard protocol (from the current
config comment).

### CI

GitHub Actions on `ubuntu-latest`: install `jq` (the rest ship with the image:
`python3`, util-linux `flock`), run `sh -n agent-priority.sh` and
`sh tests/test.sh`. Check `gh pr checks` / the run after the first push (the
runner's tool versions differ from Arch).

### The author's setup after the move

- Dotfiles: delete `terminal/.config/herdr/herdr-agent-priority.sh`,
  `terminal/.config/herdr/plugins/agent-priority/`, and `tests/herdr-agent-priority/`
  (they live in the repo now); restow so the stale symlink goes. The herdr
  README section on agent priority shrinks to a pointer at the repo.
- `herdr plugin unlink agent-priority`, then
  `herdr plugin link ~/Source/herdr-agent-priority` (development checkout, like
  omyview's).
- `config.toml`: the five `[[keys.command]]` entries switch from
  `type = "shell"` to `type = "plugin_action"`; the sidebar templates already
  have `$pri`/`$snz` from part 1.

### Testing

- Offline suite moves with the script and must pass unchanged apart from paths
  (`SCRIPT` points at the repo root). Add: `SELF` resolves via
  `HERDR_PLUGIN_ROOT`; `STATE_DIR` honours `HERDR_PLUGIN_STATE_DIR`;
  `keybind_for` finds a `plugin_action` binding.
- CI green on the first push.
- Live: after linking and reloading, each of the five keys works through its
  plugin action; the picker's alt+ binds still work (they run `$SELF`); the
  sidebar labels survive a herdr restart (startup `stamp`); ranks and snoozes
  from before the move are still there (state files moved correctly).

### Risks

- The `plugin_action` command format is documented but unvalidated by
  `config check`; the live test is the proof.
- The docs fetched are for 0.8.2 but the site now documents 0.9.1; set
  `min_herdr_version = "0.8.2"` (what it is tested on) and note it in the README.
