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
was set aside and for how long.

### Goal

A snoozed agent row shows the time left, `zz 24m` / `zz 2h10m`, next to its
rank label, updated once a minute, and gone when the snooze ends.

### Non-goals

- Second-level precision. Minutes are enough for 5m–4h snoozes.
- Any change to what alt+g, the picker or the snooze store do.

### Mechanism: expiring metadata

`herdr pane report-metadata` takes `--ttl-ms <N>` (1 ms – 24 h): the reported
metadata expires on its own. Verified on herdr 0.8.2 on 2026-09-26: a token
reported with `--ttl-ms 4000` under source `snooze-probe` was present
immediately, gone after 5 s, and tokens from other sources on the same pane
(`pri`, `prisort`, `idx`) were untouched.

The label is its own metadata report:

- **Source:** `agent-snooze`, distinct from the rank source `agent-priority`,
  so no TTL can ever expire the rank tokens.
- **Token:** `snz`.

### Mechanism: one ticker

A single background process, the **ticker**, refreshes every `snz` label once a
minute while any snooze is active.

**Every label write, from anyone, goes through the store lock.** `snooze`
writes its label inside its critical section (as the rank stamp does), `prune`
inside its own, and the ticker does each pass as a critical section too:
`locked tick_pass`. Inside it the ticker rereads the snooze store and the agent
list and reports from that fresh state, so it can never publish a label that a
`snooze` press has since extended or cleared — the press either finished before
the pass (the pass sees it) or waits for the pass to finish (and overwrites it).
A pass is a handful of local `report-metadata` calls, so it holds the lock for
tens of milliseconds.

`tick_pass`, in order:

1. Read the active snoozes (`snoozes_active`, failure → log, skip this pass)
   and the agent list with each agent's current `snz` token (failure → log,
   skip).
2. For each active snooze of a live agent: compute `remaining_ms` from `now`
   *immediately before its report*; if ≤ 0, treat it as not active (step 3);
   else report `snz=zz <left>` with `--ttl-ms min(90000, remaining_ms)`, so a
   label can never outlive its wake time.
3. Reconcile: every live agent whose current `snz` token is non-empty but which
   has no active snooze (expired, switched off, hand-edited away) gets
   `--clear-token snz`. This is driven by the agent list's tokens, not by the
   snooze snapshot, because `snoozes_active` has already filtered expired lines
   out.
4. Decide whether to keep running — see the handoff below.

Format of `<left>`: minutes rounded up, `Nm` under an hour, `NhMm` from an hour
(`2h10m`, `4h`, `1h5m`), so a fresh 5m reads `5m`, not `4m`.

**Singleton and exit/start handoff.** The ticker holds `flock -n` on
`$STATE_DIR/agent-snooze.ticker.lock` (fd 8) for its lifetime; a start that
finds it taken exits at once. The race to prevent: a ticker decides to exit, a
new snooze starts a replacement, the replacement sees the singleton lock still
held and exits, then the old ticker exits — leaving the new snooze with no
updater. It is closed by ordering both decisions under the store lock:

- The ticker decides to exit only at the end of `tick_pass`, *inside* the store
  critical section, when it found no active snooze — and it releases the
  singleton lock (`exec 8>&-`) right there, still inside, before the store lock
  is released.
- `snooze` writes the store line inside its critical section and starts the
  ticker only *after* releasing the store lock.

So either the ticker's final pass ran first — the singleton is already free
when `snooze` starts a replacement, which gets it — or the snooze ran first and
the pass sees the new line and keeps running (the replacement's `flock -n`
fails, correctly). `stamp` starts the ticker the same way, after `locked prune`.

**Self-healing.** Labels carry at most a 90 s TTL, so if the ticker dies, the
label is gone within 90 s rather than showing a wrong time; the next `snooze`
or `stamp` starts a new ticker. Nothing tracks PIDs.

**Starting it** (from `snooze` and `stamp`): after the critical section, never
inside it, detached, with fd 9 closed —
`setsid "$SELF" ticker 9>&- </dev/null >/dev/null 2>&1 &` — per the `locked`
contract. The ticker's own `locked tick_pass` opens fd 9 per pass and closes it
at the end of each, so between passes (the minute of sleep) it holds no store
lock.

### Writes outside the ticker

| When | What |
| --- | --- |
| `snooze` sets a rung | Inside the critical section: report `snz` once with the fresh time left and `--ttl-ms min(90000, remaining_ms)`, so the label appears immediately, not at the next tick. Then, outside it, ensure the ticker. |
| `snooze` reaches off | Inside the critical section: `--clear-token snz` under source `agent-snooze`. A failure is logged; the 90 s TTL removes the label anyway. |
| `stamp` | Ensure the ticker if any snooze is active (after `locked prune`). Also, inside `prune`: clear `snz` on every live agent with no active snooze but a non-empty `snz` token, so a label can never outlive its snooze by more than a stamp. |

Metadata failures in these paths are logged, never fatal: the store is the
truth, the label a projection of it.

### Risk to verify first: can a process outlive the command that starts it?

The ticker must survive the keybind / hook / action command that starts it.
herdr 0.8.2 contains a `plugin_command_limit_reached` error, so herdr may cap or
reap long-running children. The first implementation step is a live experiment:
start a `setsid`-detached `sleep 300` that writes a probe file every 30 s, from
(a) a `type = "shell"` keybind and (b) the plugin's startup hook, and confirm it
keeps running for 5 minutes and across a `herdr server reload-config`.

**Fallback if it cannot:** no ticker. The label shows the wake time instead,
`zz 14:30`, reported with `--ttl-ms` equal to the time left so herdr removes it
at the wake; `snooze` writes it, off clears it, `prune` re-reports it for active
snoozes with the time left recomputed per report (skip and clear if ≤ 0) and
clears it on live panes without an active snooze. Same source, token and
sidebar template; only the value and the TTL differ.

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
`$token` (check with `herdr config check`; if the key is reported unknown or
ignored, use the bare `"$snz"`). An unset token renders nothing, as an unranked
`$pri` does today.

### Testing

Offline, via the existing harness (the stub `herdr` appends every
`report-metadata` call to `metadata.log`). The ticker gets a test seam,
`AGENT_PRIORITY_TICK_ONCE=1`, that runs exactly one pass and exits, and the
harness puts a stub `setsid` on `PATH` that records its arguments and open fds
and does **not** run the command — so `snooze`/`stamp` never start a real ticker
in tests, and ticker behaviour is tested by calling `ticker` directly with the
seam. Tests never sleep or background anything.

1. `snooze w1:p1` → a `--source agent-snooze` report for w1:p1 with
   `--token snz=zz 5m` and `--ttl-ms 90000`.
2. Pressing through to off → the last `agent-snooze` call for w1:p1 is
   `--clear-token snz`.
3. One ticker pass with snoozes at +600 s and +7800 s, a fixture agent whose
   `snz` token is set but whose snooze line is expired, and a snooze for a gone
   pane → `zz 10m` and `zz 2h10m` with `--ttl-ms 90000`, a `--clear-token snz`
   for the expired one (driven by the token, not the snapshot), nothing for the
   gone pane.
3b. TTL clamp: a snooze with 20 s left → reported with `--ttl-ms` ≤ 20000.
3c. Ticker writes under the store lock: with `AGENT_PRIORITY_CRIT_DELAY` set,
   start a `snooze` (off rung) and a ticker pass concurrently; the final
   `agent-snooze` call for that pane in metadata.log matches the final store
   state (cleared), never a stale `zz` after the clear.
3d. Handoff: with the singleton lock held by a ticker pass that finds no active
   snooze, assert the singleton lock is free (`flock -n` succeeds) as soon as
   that pass's store critical section ends; and in the reverse order, a pass
   that runs after a snooze was written keeps the singleton.
4. Ticker singleton: with the ticker lock held by the test, a start exits at
   once without writing.
5. `stamp` with a live pane whose fixture token has `snz` set but no active
   snooze → a `--clear-token snz` for it; with the pane-list failure modes →
   no `agent-snooze` writes at all (existing guard).
6. Failed clear then recovery: make the off-rung clear fail (stub failure mode),
   then run `stamp` with the fixture still showing `snz` → the clear is issued.
7. Rank stamps still use `--source agent-priority` and never carry `--ttl-ms`.
8. `snooze` and `stamp` start the ticker with fd 9 closed: assert (via a stub
   `setsid` on PATH that records its open fds from `/proc/self/fd`) that fd 9
   is not open in the child.

Live: the process-lifetime experiment above; then snooze a pane and watch the
label count down minute by minute; press through to off and see it go; restart
herdr with a snooze active and see the label come back.

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
- **Shell-safe picker commands.** fzf runs each `execute-silent(...)` and
  `reload(...)` string through a shell, and `$SELF` is interpolated into those
  strings. Every occurrence is shell-quoted (a small `shq` helper that wraps in
  single quotes and escapes embedded ones), so a checkout at
  `/home/user/My Plugins/herdr-agent-priority` works. Tested by building the
  picker's actual bind/reload strings with `SELF` under a spaced path and
  running them through `sh -c`, not just by checking the value of `SELF`.
- **State location.** `STATE_DIR` becomes `${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-agent-priority}`.
  The fallback is a directory of its own, never inside `…/state/herdr/`, where
  `agent-priority` is already the name of the rank *file* (a fallback there
  would make `mkdir -p` fail before migration).
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
- Clean-install smoke test: an isolated herdr (its own `XDG_CONFIG_HOME`, never
  `HERDR_CONFIG_PATH`, and its own socket) with an empty config; run
  `herdr plugin install Mindful-Stack/herdr-agent-priority`, paste the README
  snippet, reload, and exercise `snooze`, `goto`, `up` through
  `herdr plugin action invoke`; confirm state lands in the plugin state dir and
  nothing is read from or written to the author's `~/.config/herdr` or
  `~/.local/state/herdr`.
- Live: after linking and reloading, each of the five keys works through its
  plugin action; the picker's alt+ binds still work (they run `$SELF`); the
  sidebar labels survive a herdr restart (startup `stamp`); ranks and snoozes
  from before the move are still there (state files moved correctly).

### Risks

- The `plugin_action` command format is documented but unvalidated by
  `config check`; the live test is the proof.
- The docs fetched are for 0.8.2 but the site now documents 0.9.1; set
  `min_herdr_version = "0.8.2"` (what it is tested on) and note it in the README.
