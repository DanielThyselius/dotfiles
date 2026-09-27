# herdr agent-priority: sidebar snooze label + shareable plugin — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show each snoozed agent's time left (`zz 24m`) in the herdr sidebar, then move the whole agent-priority feature out of dotfiles into a public, installable herdr plugin, `Mindful-Stack/herdr-agent-priority`.

**Architecture:** Part 1 changes the one POSIX sh script in place: a new `agent-snooze` metadata source carries an `snz` token with a TTL, written inside the store lock by `snooze`, `prune` and a singleton background **ticker** that refreshes the labels once a minute. Task 1 is a live gate that decides between that ticker and a no-ticker fallback (label = wake time, TTL = time left). Part 2 copies the script, manifest and offline tests into a new repo, makes every path come from herdr's plugin environment, adds `[[actions]]` so keybinds use `type = "plugin_action"`, publishes it, and switches the author's own setup over.

**Tech Stack:** POSIX sh (bash 5.3 as `sh` locally, **dash** as `sh` on the CI runner), jq 1.8, awk, util-linux `flock` and `setsid`, fzf 0.74, python3 ≥ 3.11 (`tomllib`), notify-send, herdr 0.8.2, GitHub Actions, `gh` 2.100.

**Spec:** `docs/agent/specs/2026-09-27-herdr-agent-priority-plugin-design.md` (single source of requirements).

**Branches:**
- Part 1 (Tasks 1–6): `~/dotfiles`, commits straight to `master` like all its history. The working tree has unrelated uncommitted Hyprland/Omarchy changes — **only ever `git add` the exact paths a step names**, never `-A` or `.`.
- Part 2 (Tasks 7–14): new repo `~/Source/herdr-agent-priority`, branch `main` (created explicitly with `git init -b main`, because the global `init.defaultBranch` here is `master`). Task 13 also commits to dotfiles `master`.

**LIVE HAZARD.** `~/.config/herdr/herdr-agent-priority.sh` is a stow symlink to `~/dotfiles/terminal/.config/herdr/herdr-agent-priority.sh`. Every edit to the dotfiles copy is live on the next keypress. **Never run the script outside the test harness** except where a step explicitly says so (Tasks 1, 6, 13). The harness isolates `HOME`, `XDG_STATE_HOME` and `HERDR_SOCKET_PATH`; tests must never sleep for real (beyond the script's own `AGENT_PRIORITY_CRIT_DELAY` seam) and never background a real ticker.

---

## Facts this plan relies on, and where each was checked

Checked on 2026-09-27 on this machine unless a source is named. Where the claim comes from herdr *source*, it was read in `~/Source/herdr` (a fork at `preview-2026-09-06-9e9bc8a1`, close to but **not identical** to the installed 0.8.2 binary), so it is a lead, and the live gate in Task 1 is the proof.

| Claim | Evidence |
| --- | --- |
| `setsid -f` forks, and setsid itself returns at once | setsid(1): "The command calls fork(2) if already a process group leader. Otherwise, it executes a program in the current process." / "-f, --fork  Always create a new process." Measured: `setsid -f sh -c 'sleep 2; echo done >f'` returned before `f` existed; `f` appeared ~2 s later. |
| `9>&-` on the `setsid` command closes fd 9 in the child | Measured: `exec 9>l; setsid -f sh -c 'ls -l /proc/$$/fd >out' 9>&- …` listed only 0 1 2. |
| A second `open` of a flock'd file conflicts with the first, even in one process; a child that inherited the fd keeps the lock after the parent closes it | Measured in `sh`: hold fd 8 → `flock -n "$L" true` fails ("held"); `exec 8>&-` → succeeds; start `( sleep 1 ) &` while holding fd 8, then `exec 8>&-` → still "held" until the child exits. (`man 2 flock` is not installed here, so this is measured rather than quoted.) flock(1): "-n, --nb, --nonblocking  Fail rather than wait if the lock cannot be immediately acquired." |
| fzf runs `execute`/`reload` strings through `$SHELL -c` unless told otherwise | fzf(1) 0.74.3: "--with-shell=STR  Shell command and flags to start child processes with. On *nix Systems, the default value is `$SHELL -c` if $SHELL is set, otherwise `sh -c`." |
| An action argument containing `)` can break fzf's parser | fzf(1) "ACTION ARGUMENT": "If the argument contains parentheses, fzf may fail to parse the expression." |
| `herdr pane report-metadata` has `--source`, `--token`, `--clear-token`, `--ttl-ms` | `herdr pane report-metadata --help` on 0.8.2. |
| There is **no** `herdr plugin state-dir` | `herdr plugin --help` on 0.8.2 lists `config-dir` only. |
| The plugin state dir is `${XDG_STATE_HOME:-~/.local/state}/herdr/plugins/<id>` | Source: `plugin_paths.rs` `plugin_state_dir` = `config::state_dir().join("plugins").join(id)`, and `config/io.rs` `state_dir()` honours `XDG_STATE_HOME`. On disk: `~/.local/state/herdr/plugins/agent-priority/` exists and is empty today. |
| The plugin registry is `$XDG_CONFIG_HOME/herdr/plugins.json`; the API socket is `$HERDR_SOCKET_PATH`, else `<config_dir>/herdr.sock` | Source: `persist/plugin_registry.rs`, `session.rs` `active_api_socket_path`, `config/io.rs` `config_dir()`. On disk: `~/.config/herdr/plugins.json` holds each plugin's manifest contents (hence "re-link after editing a manifest"). |
| Plugin commands get `HERDR_PLUGIN_ROOT`, `HERDR_PLUGIN_STATE_DIR`, `HERDR_SOCKET_PATH`; run with the plugin dir as cwd | herdr 0.8.2 docs, `docs/versions/0.8.2/website/src/content/docs/plugins.mdx` §"Commands and environment". |
| Keybind → action format is `type = "plugin_action"`, `command = "<plugin id>.<action id>"`; CLI is `herdr plugin action invoke <plugin id>.<action id>` | Same docs, §"Keybindings" (`command = "example.layout.apply"`) and §"Install and link" (`herdr plugin action invoke example.layout.apply`). |
| Action `contexts` values | Source `api/schema/plugins.rs` `PluginActionContext`: `global`, `workspace`, `tab`, `pane`, `selection`. |
| "Startup hooks are one-shot initialization commands rather than supervised daemons." | Same docs, §"Startup hooks". This is why Task 1 is a gate. |
| Plugin command stdout/stderr are **pipes** herdr reads to EOF; a command counts against `MAX_PLUGIN_COMMANDS_IN_FLIGHT = 32` until then (the `plugin_command_limit_reached` error) | Source `app/api/plugins/runtime.rs` `start_plugin_command`. A ticker that kept the pipes open would keep its starter "running" forever and eat the limit; hence `>/dev/null 2>&1` on every start. |
| `herdr config check` rejects unknown keys in a styled sidebar token and accepts `dim` on a custom `$token` | Measured with a scratch copy of `config.toml` (`HERDR_CONFIG_PATH=<copy> herdr config check`, read-only): `{ token = "$snz", dim = true }` → `config: ok`; `{ token = "$snz", dimm = true }` → `data did not match any variant of untagged enum RawSidebarToken`, exit 1. Source `config/sidebar.rs`: the style applies to any token. |
| `stow -R` prunes links to files that left the package | stow(8): "--restow  Restow packages (first unstow, then stow again). This is useful for pruning obsolete symlinks from the target tree after updating the software in a package." |
| Existing offline suite: 46 checks pass | `sh ~/dotfiles/tests/herdr-agent-priority/test.sh` — 46 `ok`, one expected jq error line on stderr (the `errjson` mode). |

## Environment assumptions (pinned)

- **`sh` differs**: bash 5.3 here, dash on `ubuntu-latest`. Scripts and tests stay POSIX: no `local`, no `[[`, no arrays, no `$'…'`. Env-prefixed calls use `VAR=x sh "$SCRIPT" …` (a simple command), not `VAR=x some_function` — assignments before a *function* call are not portable.
- **Timezone**: every `HH:MM` expectation is computed in the test with the same `date -d @… +%H:%M` the script uses, so a UTC runner and a local laptop agree.
- **Unix socket path length** (108 bytes): socket paths in tests live directly under `mktemp -d` output (`/tmp/tmp.XXXXXXXXXX/t.XXXXXX/view.sock`, ~40 bytes).
- **umask**: nothing asserts a file mode; the Part 2 check that matters is the git-recorded mode `100755` of `agent-priority.sh`, which is independent of umask.
- **git**: `git init -b main` pins the branch; commits use the ambient `user.email` (`daniel@mindfulstack.se`).
- **Not root**: `flock` conflicts are real for any uid; nothing here depends on `access(2)`.

---

## File map

Part 1 (`~/dotfiles`):

| Path | Responsibility |
| --- | --- |
| `terminal/.config/herdr/herdr-agent-priority.sh` | The feature. Tasks 3–5 (or 3 + 4F). |
| `tests/herdr-agent-priority/test.sh` | Offline runner. Every code task. |
| `tests/herdr-agent-priority/bin/herdr` | Stub CLI; gains an `agent-snooze` write-failure mode (Task 2). |
| `tests/herdr-agent-priority/bin/setsid` | **Create** (Task 2). Records how a process would be started and which fds it would inherit; never starts it. |
| `tests/herdr-agent-priority/bin/sleep` | **Create** (Task 2). Passes short sleeps through; refuses the ticker's `sleep 60`, so a test that forgets the tick-once seam fails instead of hanging. |
| `terminal/.config/herdr/config.toml` | Sidebar templates, comments (Task 6); keybinds → `plugin_action` (Task 13). |
| `terminal/.config/herdr/README.md` | Snooze label docs (Task 6); shrinks to a pointer (Task 13). |
| `terminal/.config/herdr/plugins/agent-priority/herdr-plugin.toml` | Temporary probe action (Task 1, removed again); deleted (Task 13). |
| `docs/agent/specs/2026-09-27-herdr-agent-priority-plugin-design.md` | Gate result recorded (Task 1). |

Part 2 (`~/Source/herdr-agent-priority`, all **created**):

| Path | Responsibility |
| --- | --- |
| `agent-priority.sh` | The script (was `herdr-agent-priority.sh`), git mode `100755`. |
| `herdr-plugin.toml` | Manifest: startup, events, picker pane, five actions. |
| `tests/test.sh`, `tests/agents.json`, `tests/bin/{herdr,notify-send,setsid,sleep,fzf}` | Offline suite and stubs. `bin/fzf` is new (Task 8). |
| `tests/config.toml` | The config the key-hint tests read: `[keys] prefix` + the README keys snippet, byte-for-byte. |
| `README.md`, `LICENSE`, `.github/workflows/test.yml` | Docs, MIT licence, CI. |

---

# Part 1 — show snoozes in the sidebar (`~/dotfiles`)

### Task 1: GATE — can a detached process outlive the command that starts it?

Everything the ticker design assumes rests on this. **Do not start Task 3 until this task's result is recorded.** It is live and partly human: step 5 needs the user to press a key.

**What selects which branch:**

- **Ticker branch** (Tasks 3, 4, 5, 6) — *all* of these hold:
  1. `action.log` and `keybind.log` each show `stamps=11 steady finished=1` (11 heartbeats 30 s apart, no gap > 35 s, the loop ran to its end), with a `herdr server reload-config` having happened while each was running;
  2. the probe action's entry in `herdr plugin log list` is `succeeded` within about a second of starting — not `running` (a `running` entry means herdr is still holding the command's pipes, which would exhaust the 32-command limit over a day).
- **Fallback branch** (Tasks 3-fallback variant, 4F, 6) — any of the above fails. Tasks 4 and 5 are then **not done**; Task 4F replaces both.

Both paths matter: in Part 1 the ticker is started from a `type = "shell"` keybind (`snooze`) and from plugin hooks (`stamp`); in Part 2 everything is a plugin action. The action path in (a) runs through the same `start_plugin_command` as startup and event hooks (source `runtime.rs`); the startup hook itself is confirmed in Task 6's live check.

**Files:**
- Create (outside any repo): `~/.local/state/herdr-probe/probe.sh`, `~/.local/state/herdr-probe/verify.sh`
- Temporarily modify, then restore: `~/dotfiles/terminal/.config/herdr/plugins/agent-priority/herdr-plugin.toml`, `~/dotfiles/terminal/.config/herdr/config.toml`
- Modify: `~/dotfiles/docs/agent/specs/2026-09-27-herdr-agent-priority-plugin-design.md` (record the result)

- [ ] **Step 1: Write the probe**

`~/.local/state/herdr-probe/probe.sh`:

```sh
#!/bin/sh
# Lifetime probe for the ticker gate. `start <label>` detaches a heartbeat
# exactly the way ensure_ticker will (setsid -f, fd 9 closed, stdio on
# /dev/null) and returns at once. `beat <label>` writes an epoch line every
# 30 s, 11 times — five minutes — then "finished".
set -eu
dir="$HOME/.local/state/herdr-probe"
case $1 in
start)
  printf 'start %s from pid %s\n' "$(date +%s)" "$$" >>"$dir/$2.log"
  setsid -f sh "$dir/probe.sh" beat "$2" 9>&- </dev/null >/dev/null 2>&1
  ;;
beat)
  printf 'beat pid %s sid %s\n' "$$" "$(ps -o sid= -p "$$" | tr -d ' ')" >>"$dir/$2.log"
  i=0
  while [ "$i" -lt 11 ]; do
    date +%s >>"$dir/$2.log"
    i=$((i + 1))
    [ "$i" -lt 11 ] && sleep 30
  done
  echo finished >>"$dir/$2.log"
  ;;
esac
```

`~/.local/state/herdr-probe/verify.sh`:

```sh
#!/bin/sh
# Summarise each probe log: heartbeat count, whether any gap exceeded 35 s,
# and whether the loop reached its end.
for l in action keybind; do
  f="$HOME/.local/state/herdr-probe/$l.log"
  [ -f "$f" ] || { echo "$l: no log"; continue; }
  n=$(grep -c '^[0-9][0-9]*$' "$f" || true)
  gap=$(awk '/^[0-9]+$/ { if (p && $1 - p > 35) g = 1; p = $1 } END { print g ? "gap" : "steady" }' "$f")
  fin=$(grep -cx finished "$f" || true)
  echo "$l: stamps=$n $gap finished=$fin"
done
```

Run: `mkdir -p ~/.local/state/herdr-probe && chmod +x ~/.local/state/herdr-probe/*.sh`

- [ ] **Step 2: Add the temporary action and re-link (agent can do this)**

Append to `~/dotfiles/terminal/.config/herdr/plugins/agent-priority/herdr-plugin.toml`:

```toml

# TEMPORARY — Task 1 lifetime probe. Remove before committing anything.
[[actions]]
id = "lifetime-probe"
title = "Lifetime probe (temporary)"
contexts = ["global"]
command = ["sh", "-c", "exec sh \"$HOME/.local/state/herdr-probe/probe.sh\" start action"]
```

Run:
```bash
herdr plugin link ~/dotfiles/terminal/.config/herdr/plugins/agent-priority
herdr plugin action list --plugin agent-priority
```
Expected: the list contains `lifetime-probe`. (The registry caches manifest contents, so without the re-link the action does not exist.)

- [ ] **Step 3: Invoke it and check the starter finished**

```bash
herdr plugin action invoke agent-priority.lifetime-probe
for i in $(seq 50); do
  st=$(herdr plugin log list --plugin agent-priority --limit 5 |
    jq -r '[.result.logs[] | select(.action_id == "lifetime-probe")] | last | "\(.status) \((.finished_unix_ms // 0) - .started_unix_ms)ms"')
  case $st in running*|null*|'') command -p sleep 0.2 ;; *) break ;; esac
done
echo "$st"
```
`action invoke` returns as soon as herdr has *started* the command (the log record comes back at start), so the first read can legitimately say `running`; the loop polls for up to ~10 s. Expected: `succeeded <small>ms` (the probe's `start` branch runs in milliseconds). Still `running` after 10 s is a gate failure (condition 2): herdr is holding the command's pipes. Note the wall-clock time; call it T0.

- [ ] **Step 4: Add the temporary keybind (agent), then reload — this reload happens while the action probe runs**

Append to `~/dotfiles/terminal/.config/herdr/config.toml` (end of the `--- custom commands ---` area; `prefix+ctrl+l` is unused in this file — `grep -n 'ctrl+l' config.toml` prints nothing):

```toml

# TEMPORARY — Task 1 lifetime probe. Remove before committing anything.
[[keys.command]]
key = "prefix+ctrl+l"
type = "shell"
command = 'sh -c "sh $HOME/.local/state/herdr-probe/probe.sh start keybind"'
description = "Lifetime probe (temporary)"
```

Run:
```bash
herdr config check && herdr server reload-config
```
Expected: `config: ok`, then the reload succeeds. Must happen between T0+60 s and T0+240 s so it lands mid-run for the action probe.

- [ ] **Step 5: HUMAN — press the probe key**

Ask the user: "Please press `alt+space` then `ctrl+l` once, in any pane, and tell me when you have." Note the time T1. Confirm `~/.local/state/herdr-probe/keybind.log` has a `start` and a `beat` line.

- [ ] **Step 6: Reload again while the keybind probe runs**

Between T1+60 s and T1+240 s: `herdr server reload-config`.

- [ ] **Step 7: Read the result after both runs end**

After T1+320 s (keep the laptop awake; a suspend invalidates the run — redo it). In Claude Code, wait with the Monitor tool and an until-loop (`until grep -qx finished ~/.local/state/herdr-probe/keybind.log; do …`), not a foreground `sleep`, which the Bash tool blocks.

Run: `sh ~/.local/state/herdr-probe/verify.sh`
Ticker branch expected:
```
action: stamps=11 steady finished=1
keybind: stamps=11 steady finished=1
```
Anything else → fallback branch.

- [ ] **Step 8: Remove the temporary entries, re-link, reload, clean up**

Delete the two appended blocks (manifest and config), then:
```bash
cd ~/dotfiles && git diff --stat -- terminal/.config/herdr/
herdr plugin link ~/dotfiles/terminal/.config/herdr/plugins/agent-priority
herdr plugin action list --plugin agent-priority
herdr config check && herdr server reload-config
rm -rf ~/.local/state/herdr-probe
```
Expected: `git diff --stat` prints nothing for those two files; the action list no longer contains `lifetime-probe`.

- [ ] **Step 9: Record the result in the spec and commit**

In the spec's "Risk to verify first" section, append a paragraph:

```markdown
**Result (YYYY-MM-DD):** <ticker | fallback>. Action probe: `<verify line>`,
plugin log `<status, duration>`. Keybind probe: `<verify line>`. Reloads at
T0+<n>s and T1+<n>s. <One sentence on anything unexpected.>
```

```bash
cd ~/dotfiles
git add docs/agent/specs/2026-09-27-herdr-agent-priority-plugin-design.md
git commit -m "docs: agent-priority spec - record the process-lifetime gate result

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013eVjtaWhwxCpkrmZkWssH1"
```

---

### Task 2: Harness additions (shared test infrastructure — highest stakes)

Every later Part-1 test, and all of Part 2's, asserts through what this task builds. A stub that is healthy for the wrong reason makes every later check pass while the real thing is broken.

**What the stubs must genuinely reproduce:**
- `setsid`: the *arguments* the script passes and the *set of open fds* the started process would inherit, recorded synchronously (the script calls `setsid -f` without `&`, so the stub finishes before the script returns — no polling, no race).
- `herdr pane report-metadata … --source agent-snooze …` failing with a nonzero exit and **no** `metadata.log` line, while `--source agent-priority` writes keep working — the failure is scoped to the snooze label so rank stamps are unaffected.
- A fixture agent whose `tokens.snz` is set, as `herdr agent list` would show a label still on screen.

**What the environment cannot supply:** the stub's tokens never change after a write (unchanged from before). A test that needs "the label is still showing" must set `tokens.snz` in the fixture itself; a test that asserts a label was *written* reads `metadata.log`, never a later `agent list`. The stub cannot model TTL expiry; TTL behaviour is only asserted as the `--ttl-ms` value passed, and proven live in Task 6.

**Properties that must not collapse:**
- "fd 9 open in the child" must be *observable* by the stub, or every later "fd 9 is closed" check passes vacuously. Step 4 proves the stub sees an inherited fd 9.
- The failure mode must not also break `agent-priority` writes, or the failed-clear test can't tell "snooze label failed" from "everything failed".

**Files:**
- Create: `tests/herdr-agent-priority/bin/setsid`, `tests/herdr-agent-priority/bin/sleep`
- Modify: `tests/herdr-agent-priority/bin/herdr` (the `"pane report-metadata"` case)
- Modify: `tests/herdr-agent-priority/test.sh` (`setup`, new helpers, harness self-checks before `exit "$failed"`)

- [ ] **Step 1: Stub `setsid`**

`tests/herdr-agent-priority/bin/setsid`:

```sh
#!/bin/sh
# Stub setsid: record how the script tried to start a process and which fds
# that process would have inherited — and never start it, so no test ever runs
# a real ticker. One line per call:
#   args=[-f /path/agent-priority.sh ticker] fds=[ 0 1 2 255 ]
# fds is space-padded so " 9 " matches fd 9 and nothing else.
fds=' '
for f in /proc/$$/fd/*; do fds="$fds${f##*/} "; done
printf 'args=[%s] fds=[%s]\n' "$*" "$fds" >>"$FIXTURE_DIR/setsid.log"
```

- [ ] **Step 2: Stub `sleep`**

`tests/herdr-agent-priority/bin/sleep`:

```sh
#!/bin/sh
# Stub sleep: the script's own short test delays (AGENT_PRIORITY_CRIT_DELAY)
# pass through to the real sleep; the ticker's minute between passes is
# refused, so a test that forgets AGENT_PRIORITY_TICK_ONCE fails at once
# instead of hanging the runner. `command -p` searches the default system
# PATH, which does not contain this directory.
case ${1:-} in
60) echo "stub sleep: refusing 'sleep 60' — use AGENT_PRIORITY_TICK_ONCE" >&2; exit 1 ;;
*) command -p sleep "$@" ;;
esac
```

(Not `exec command -p …`: `exec` takes a program, and `command` is a builtin. The property: short sleeps really sleep; `sleep 60` exits nonzero without sleeping.)

Run: `chmod +x ~/dotfiles/tests/herdr-agent-priority/bin/setsid ~/dotfiles/tests/herdr-agent-priority/bin/sleep`

- [ ] **Step 3: Stub `herdr` failure mode for the snooze label**

In `tests/herdr-agent-priority/bin/herdr`, replace the line

```sh
"pane report-metadata") printf '%s\n' "$*" >>"$F/metadata.log" ;;
```

with

```sh
"pane report-metadata")
  # Test seam: HERDR_STUB_FAIL_SNOOZE_META=1 makes every write under the
  # agent-snooze source fail (nonzero, nothing logged), as a server that
  # rejects the call would. Rank writes (agent-priority) are unaffected.
  case " $* " in
  *" --source agent-snooze "*)
    if [ -n "${HERDR_STUB_FAIL_SNOOZE_META:-}" ]; then
      echo "stub herdr: forced agent-snooze failure" >&2
      exit 1
    fi
    ;;
  esac
  printf '%s\n' "$*" >>"$F/metadata.log"
  ;;
```

- [ ] **Step 4: Harness plumbing and self-checks in `test.sh`**

In `setup()`, extend the first `unset` line and add a log reset:

```sh
  unset AGENT_PRIORITY_CRIT_DELAY HERDR_STUB_FAIL_PANE_LIST \
    AGENT_PRIORITY_TICK_ONCE AGENT_PRIORITY_TICK_PROBE \
    HERDR_STUB_FAIL_SNOOZE_META 2>/dev/null || true
```

and after `: >"$FIXTURE_DIR/calls.log"`:

```sh
  : >"$FIXTURE_DIR/setsid.log"
```

After the `queue_ids()` helper, add:

```sh
seed_snooze() { # seed_snooze <pane> <seconds from now, may be negative> <step>
  mkdir -p "$(dirname "$(state agent-snooze)")"
  printf '%s\t%s\t%s\n' "$1" $(( $(date +%s) + $2 )) "$3" >>"$(state agent-snooze)"
}
set_snz() { # set_snz <pane> <label>: the fixture shows this pane's $snz as set
  fixture ".result.agents |= map(if .pane_id == \"$1\" then .tokens.snz = \"$2\" else . end)"
}
snz_lines() { # snz_lines <pane>: this pane's agent-snooze writes, oldest first
  awk -v p="$1" '$3 == p && / --source agent-snooze /' "$FIXTURE_DIR/metadata.log"
}
# One ticker pass and exit. Never call `run ticker` without the seam: the
# stub sleep refuses the minute's wait, but the pass count would be wrong.
ticker_once() { AGENT_PRIORITY_TICK_ONCE=1 sh "$SCRIPT" ticker || true; }
fd9_in() { # fd9_in <setsid.log line number>: yes if that start inherited fd 9
  sed -n "${1}p" "$FIXTURE_DIR/setsid.log" | grep -qF ' 9 ' && echo yes || echo no
}
```

In the existing "picker rows show snoozes" block, the line
`wake=$(awk -F'\t' '$1 == "w1:p1" { print $2 }' "$(state agent-snooze)")` is a bare assignment: if the store is missing (as it is in Task 8's red run, when script and harness disagree on the state dir) its failure aborts the whole runner under `set -e` and every later check silently disappears. Append ` 2>/dev/null || true` inside the `$( … )`, matching the harness rule "never abort the runner". Every `wake=$(awk …)` in later tasks carries the same guard.

Immediately before the final `exit "$failed"`, add the harness self-checks:

```sh
# --- harness self-checks (Task 2) ---------------------------------------------
# These prove the stubs can see what later tests assert on. If the fd probe
# could not see an inherited fd 9, every "ticker starts with fd 9 closed"
# check below would pass whatever the script did.
setup
( exec 9>"$T/probe.lock"; setsid -f probe-target ticker )
setsid -f probe-target ticker
check "stub setsid records its arguments" "args=[-f probe-target ticker]" \
  "$(sed -n 1p "$FIXTURE_DIR/setsid.log" | sed 's/ fds=.*//')"
check "stub setsid sees an inherited fd 9" "yes" "$(fd9_in 1)"
check "stub setsid sees fd 9 absent when it is" "no" "$(fd9_in 2)"

setup
code=0
HERDR_STUB_FAIL_SNOOZE_META=1 herdr pane report-metadata w1:p1 \
  --source agent-snooze --clear-token snz 2>/dev/null || code=$?
check "stub failure mode fails agent-snooze writes" "1" "$code"
HERDR_STUB_FAIL_SNOOZE_META=1 herdr pane report-metadata w1:p1 \
  --source agent-priority --token prisort=3 >/dev/null
check "stub failure mode leaves agent-priority writes alone" \
  "pane report-metadata w1:p1 --source agent-priority --token prisort=3" \
  "$(cat "$FIXTURE_DIR/metadata.log")"

setup
set_snz w1:p2 "zz 3m"
check "fixture can show a live \$snz label" "zz 3m" \
  "$(herdr agent list | jq -r '.result.agents[] | select(.pane_id == "w1:p2") | .tokens.snz')"

code=0; sleep 60 2>/dev/null || code=$?
check "stub sleep refuses the ticker's minute" "1" "$code"
```

What these distinguish: the fd-9 pair goes red if the stub cannot see its inherited fds (e.g. it lists some other process's fds, or drops the padding so ` 9 ` never matches); the failure-mode pair goes red if the mode leaks to rank writes or does not fail at all; the fixture check goes red if `set_snz` writes the wrong key; the sleep check goes red if `sleep 60` would really sleep (the runner would then take a minute here — also visible).

- [ ] **Step 5: Run the suite**

Run: `sh ~/dotfiles/tests/herdr-agent-priority/test.sh 2>/dev/null | grep -c '^ok'; sh ~/dotfiles/tests/herdr-agent-priority/test.sh 2>/dev/null | grep FAIL || echo no-fails`
Expected: `53` and `no-fails` (46 existing + 7 self-checks). Infrastructure checks pass on first run by design; Step 6 proves they can fail.

- [ ] **Step 6: Prove the fd probe can fail for the stated reason**

Drop the padding: change `fds=' '` to `fds=''` and `"$fds${f##*/} "` to `"$fds${f##*/}"` (the list becomes `0129255`, in which ` 9 ` can never match). Rerun: "stub setsid sees an inherited fd 9" must FAIL. Revert; rerun: all ok.

- [ ] **Step 7: Commit**

```bash
cd ~/dotfiles
git add tests/herdr-agent-priority/bin/setsid tests/herdr-agent-priority/bin/sleep \
  tests/herdr-agent-priority/bin/herdr tests/herdr-agent-priority/test.sh
git commit -m "herdr tests: stub setsid/sleep, agent-snooze write failure mode, snz fixture helpers

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013eVjtaWhwxCpkrmZkWssH1"
```

---

### Task 3: `snooze` writes and clears the `snz` label inside its critical section

Both branches do this task; only `snz_report`'s value and TTL differ (fallback variant at the end of the task). In the ticker branch, `snooze` also ensures the ticker, after the lock.

**Interim note (ticker branch):** the script is live the moment this commits. Until Task 4 lands, `ticker` is an unknown subcommand, so the detached start exits with "unknown command" (logged) and a label vanishes after its 90 s TTL. Harmless; Task 4 follows directly.

**Files:**
- Modify: `terminal/.config/herdr/herdr-agent-priority.sh` — constants block (line ~65–73), after `snooze_label()` (~line 232), `snooze_step()` (~234–260), the `snooze)` case (~596–610)
- Test: `tests/herdr-agent-priority/test.sh`

- [ ] **Step 1: Write the failing tests** (insert after the existing "snooze ladder" block, before "queue skips snoozed panes")

```sh
# --- snooze writes the sidebar label (Task 3) ----------------------------------
setup
run snooze w1:p1
check "a snooze labels the pane under its own source, 5m, TTL clamped to 90s" \
  "pane report-metadata w1:p1 --source agent-snooze --token snz=zz 5m --ttl-ms 90000" \
  "$(snz_lines w1:p1)"

setup
for _ in 1 2 3 4 5; do run snooze w1:p1; done
check "pressing through to off clears the label last" \
  "pane report-metadata w1:p1 --source agent-snooze --clear-token snz" \
  "$(snz_lines w1:p1 | tail -n1)"

setup
run up w1:p2
run snooze w1:p2
check "rank stamps never carry a TTL" "" \
  "$(awk '/ --source agent-priority / && / --ttl-ms /' "$FIXTURE_DIR/metadata.log")"
check "the snz token is only ever written under agent-snooze" "" \
  "$(awk '/snz/ && !/ --source agent-snooze /' "$FIXTURE_DIR/metadata.log")"

setup
seed_snooze w1:p1 600 240
code=0; HERDR_STUB_FAIL_SNOOZE_META=1 sh "$SCRIPT" snooze w1:p1 2>/dev/null || code=$?
check "a failed label clear is not fatal: exit 0" "0" "$code"
check "a failed label clear still switches the snooze off" "" \
  "$(awk -F'\t' '$1 == "w1:p1"' "$(state agent-snooze)")"
check "a failed label clear still toasts" "yes" \
  "$(tail -n1 "$FIXTURE_DIR/toasts.log" | grep -qF 'Snooze off' && echo yes || echo no)"
check "a failed label clear is logged" "yes" \
  "$(grep -qF 'snooze: snz clear failed for w1:p1' "$(state agent-priority.log)" && echo yes || echo no)"

# Ticker branch only — delete these three checks in the fallback branch.
setup
run snooze w1:p1
check "snooze starts the ticker, detached" \
  "args=[-f $HOME/.config/herdr/herdr-agent-priority.sh ticker]" \
  "$(sed -n 1p "$FIXTURE_DIR/setsid.log" | sed 's/ fds=.*//')"
check "snooze starts the ticker with fd 9 closed" "no" "$(fd9_in 1)"
for _ in 2 3 4 5; do run snooze w1:p1; done
check "the off press does not start a ticker" "4" "$(grep -c '' "$FIXTURE_DIR/setsid.log")"
```

What each distinguishes:
- *labels … 5m, TTL 90000*: no label write at all; the wrong source (a rank-source write would let a TTL expire `pri`/`prisort`); floor rounding (`4m`); an unclamped TTL (`300000`).
- *clears the label last*: off leaving the label up until its TTL.
- *never carry a TTL / only under agent-snooze*: folding `snz` into `stamp_one`'s rank report.
- *failed clear …*: a metadata failure that aborts the critical section under `set -e` (exit 1, no toast). The "switches off" check passes before the change too (no metadata call exists yet) — the discriminating ones are exit code, toast and log line.
- *starts the ticker / fd 9 closed / off does not*: no start; a start inside `locked` (fd 9 inherited — see Step 6); a start on every press including off.

- [ ] **Step 2: Run to see them fail for the stated reasons**

Run: `sh ~/dotfiles/tests/herdr-agent-priority/test.sh 2>/dev/null | grep -A2 FAIL`
Expected FAILs: "labels the pane…" (actual empty — no write exists), "clears the label last" (empty), "failed label clear is logged" (no), "starts the ticker, detached" (empty), "the off press does not start a ticker" (`0`). "fd 9 closed" reads `no` from an empty log and passes vacuously here; Step 6 is its real proof.

- [ ] **Step 3: Implement**

Constants block — after `LOCK="$STATE_DIR/agent-priority.lock"` add:

```sh
SNZ_SOURCE=agent-snooze
TICKER_LOCK="$STATE_DIR/agent-snooze.ticker.lock"
```

After `snooze_label()`:

```sh
# THE SIDEBAR LABEL. A snoozed row shows its time left as the $snz token,
# "zz 24m". It is a separate metadata source from the ranks on purpose: the
# label carries a TTL, and a TTL on the agent-priority source would expire
# pri and prisort with it. The TTL is the safety net — never longer than 90 s
# and never past the wake — so a label nobody refreshes disappears instead of
# showing a wrong time. Every write goes through the store lock, like the rank
# stamp, and a failed write is logged, never fatal: the store is the truth, the
# label a projection of it.
snooze_left() { # snooze_left <seconds>: minutes rounded up — 5m, 59m, 1h, 1h5m, 2h10m, 4h
  m=$(( ($1 + 59) / 60 ))
  if [ "$m" -lt 60 ]; then
    echo "${m}m"
  elif [ $((m % 60)) -eq 0 ]; then
    echo "$((m / 60))h"
  else
    echo "$((m / 60))h$((m % 60))m"
  fi
}

snz_clear() { # snz_clear <pane_id> <caller>
  herdr pane report-metadata "$1" --source "$SNZ_SOURCE" --clear-token snz >/dev/null ||
    log "$2: snz clear failed for $1"
}

# The time left is computed here, immediately before the report, so a label
# can never be written with a TTL that outlives its wake. A wake already past
# means the snooze is over: clear instead.
snz_report() { # snz_report <pane_id> <wake_epoch> <caller>
  left=$(( $2 - $(date +%s) ))
  if [ "$left" -le 0 ]; then
    snz_clear "$1" "$3"
    return 0
  fi
  ttl=$(( left * 1000 ))
  [ "$ttl" -le 90000 ] || ttl=90000
  herdr pane report-metadata "$1" --source "$SNZ_SOURCE" \
    --token "snz=zz $(snooze_left "$left")" --ttl-ms "$ttl" >/dev/null ||
    log "$3: snz report failed for $1"
}

# Start the ticker, detached, unless one already runs (it checks that itself
# and exits at once). Called only AFTER a `locked` section has returned, never
# inside one: a child started in there inherits fd 9 and holds the store lock
# for its whole life (see `locked`). fd 9 is closed explicitly anyway.
#
# `setsid -f` "Always create[s] a new process" (setsid(1)): it forks, the child
# starts a new session and becomes the ticker, and setsid itself returns at
# once — so nothing here is a background job. stdio goes to /dev/null because
# a plugin command's stdout/stderr are pipes herdr reads until EOF: a ticker
# holding them would leave the command that started it "running" in herdr's
# plugin log, and herdr caps those at 32.
ensure_ticker() {
  setsid -f "$SELF" ticker 9>&- </dev/null >/dev/null 2>&1 ||
    log "ensure_ticker: could not start the ticker"
}
```

In `snooze_step()`, between `mv "$tmp" "$SNOOZE"` and `rm -f "$snap"`, add:

```sh
  # Inside the lock, like rank_write's stamp: outside it, two quick presses
  # could store 30m then 2h but label 2h then 30m.
  if [ -n "$step" ]; then
    snz_report "$1" "$wake" snooze
  else
    snz_clear "$1" snooze
  fi
```

In the `snooze)` case, directly after `locked snooze_step "$pane"`:

```sh
  # After the lock, never inside it. Off needs no ticker: the label is already
  # cleared, and a running ticker notices the empty store on its next pass.
  [ -z "$step" ] || ensure_ticker
```

Properties: the report and clear are *inside* `snooze_step` (so inside `locked`); `ensure_ticker` is *outside*; no metadata failure can make `snooze` exit nonzero.

- [ ] **Step 4: Run the suite**

Run: `sh ~/dotfiles/tests/herdr-agent-priority/test.sh 2>/dev/null | grep -c '^ok'; sh ~/dotfiles/tests/herdr-agent-priority/test.sh 2>/dev/null | grep FAIL || echo no-fails`
Expected: `64`, `no-fails` (53 + 11).

- [ ] **Step 5: Syntax check**

Run: `sh -n ~/dotfiles/terminal/.config/herdr/herdr-agent-priority.sh && echo ok`
Expected: `ok`.

- [ ] **Step 6: Prove the fd-9 check can fail for the stated reason**

Temporarily (a) move `[ -z "$step" ] || ensure_ticker` from the `snooze)` case to the end of `snooze_step()` — inside the critical section — and (b) delete `9>&- ` from `ensure_ticker`. Rerun: "snooze starts the ticker with fd 9 closed" must FAIL (`yes`: the child inherited `locked`'s fd 9). Restore (b) only and rerun: it passes again, because `9>&-` alone keeps fd 9 out of the child — which is why the explicit close stays as belt-and-braces next to the placement rule. Revert (a); rerun: all ok.

- [ ] **Step 7: Commit**

```bash
cd ~/dotfiles
git add terminal/.config/herdr/herdr-agent-priority.sh tests/herdr-agent-priority/test.sh
git commit -m "herdr: snooze labels the sidebar (snz, own source, TTL <= 90s), starts the ticker after the lock

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013eVjtaWhwxCpkrmZkWssH1"
```

#### Task 3 — fallback-branch variant (only if Task 1 chose the fallback)

Same steps, with these differences:

- `snz_report` reports the **wake time** with TTL = the whole time left (no 90 s clamp; ≤ 4 h is inside herdr's 24 h limit):

```sh
snz_report() { # snz_report <pane_id> <wake_epoch> <caller>  (fallback: no ticker)
  left=$(( $2 - $(date +%s) ))
  if [ "$left" -le 0 ]; then
    snz_clear "$1" "$3"
    return 0
  fi
  herdr pane report-metadata "$1" --source "$SNZ_SOURCE" \
    --token "snz=zz $(date -d "@$2" +%H:%M)" --ttl-ms "$((left * 1000))" >/dev/null ||
    log "$3: snz report failed for $1"
}
```

- No `snooze_left`, no `TICKER_LOCK`, no `ensure_ticker`, no `[ -z "$step" ] || ensure_ticker`; the comment says the label shows the wake time and herdr removes it at the wake.
- Replace the first test with:

```sh
setup
run snooze w1:p1
wake=$(awk -F'\t' '$1 == "w1:p1" { print $2 }' "$(state agent-snooze)" 2>/dev/null || true)
line=$(snz_lines w1:p1)
check "a snooze labels the pane with its wake time" "yes" \
  "$(printf '%s\n' "$line" | grep -qF -- "--token snz=zz $(date -d "@$wake" +%H:%M) --ttl-ms " && echo yes || echo no)"
ttl=$(printf '%s\n' "$line" | sed 's/.*--ttl-ms //')
check "the label's TTL is the time left (299-300s)" "yes" \
  "$([ "$ttl" -ge 299000 ] && [ "$ttl" -le 300000 ] && echo yes || echo no)"
```
  (distinguishes: a clamped 90 s TTL, which without a ticker would drop the label after 90 s; the wrong value format.)
- Delete the three "ticker branch only" checks and add one: `check "no ticker is ever started" "" "$(cat "$FIXTURE_DIR/setsid.log")"` after a `run snooze w1:p1`.
- Expected counts: `63` after Step 4 (53 + 10).
- Skip Step 6. Commit message: `herdr: snooze labels the sidebar with its wake time (snz, own source, TTL to the wake)`.

---

### Task 4 (ticker branch): the ticker

**Files:**
- Modify: `terminal/.config/herdr/herdr-agent-priority.sh` — new functions after `ensure_ticker()`; new `ticker)` case before `*)`; header usage comment (lines 4–15)
- Test: `tests/herdr-agent-priority/test.sh`

- [ ] **Step 1: Write the failing tests** (new block after the Task 3 block)

```sh
# --- ticker (Task 4) -------------------------------------------------------------
# One pass. w1:p1 and w1:p4 are snoozed and live; w1:p2's line has expired but
# its label is still on screen (fixture token); w9:gone is snoozed but not live.
setup
seed_snooze w1:p1 600 30
seed_snooze w1:p4 7800 240
seed_snooze w1:p2 -1 30
seed_snooze w9:gone 600 30
set_snz w1:p2 "zz 1m"
ticker_once
check "tick refreshes a live snooze (10m, 90s TTL)" \
  "pane report-metadata w1:p1 --source agent-snooze --token snz=zz 10m --ttl-ms 90000" \
  "$(snz_lines w1:p1)"
check "tick formats hours as NhMm" \
  "pane report-metadata w1:p4 --source agent-snooze --token snz=zz 2h10m --ttl-ms 90000" \
  "$(snz_lines w1:p4)"
check "tick clears a label whose snooze expired (token-driven)" \
  "pane report-metadata w1:p2 --source agent-snooze --clear-token snz" \
  "$(snz_lines w1:p2)"
check "tick writes nothing for a gone pane" "" "$(snz_lines w9:gone)"
check "tick writes nothing for a pane with no snooze and no label" "" "$(snz_lines w1:p3)"

setup
seed_snooze w1:p1 300 5
seed_snooze w1:p2 3900 120
seed_snooze w1:p3 14400 240
ticker_once
check "5m rounds up, not down" "yes" "$(snz_lines w1:p1 | grep -qF 'snz=zz 5m ' && echo yes || echo no)"
check "65 minutes is 1h5m" "yes" "$(snz_lines w1:p2 | grep -qF 'snz=zz 1h5m ' && echo yes || echo no)"
check "a whole hour drops the minutes (4h)" "yes" "$(snz_lines w1:p3 | grep -qF 'snz=zz 4h ' && echo yes || echo no)"

setup
seed_snooze w1:p1 20 5
ticker_once
ttl=$(snz_lines w1:p1 | sed 's/.*--ttl-ms //')
check "TTL never outlives the wake (20s left -> <= 20000)" "yes" \
  "$([ -n "$ttl" ] && [ "$ttl" -ge 1 ] && [ "$ttl" -le 20000 ] && echo yes || echo no)"

# A label-write failure is logged and the pass carries on to the next pane.
setup
seed_snooze w1:p1 600 30
seed_snooze w1:p4 600 30
code=0; AGENT_PRIORITY_TICK_ONCE=1 HERDR_STUB_FAIL_SNOOZE_META=1 sh "$SCRIPT" ticker 2>/dev/null || code=$?
check "a failed tick write is not fatal" "0" "$code"
check "a failed tick write is logged, and the next pane is still tried" "2" \
  "$(grep -c 'tick: snz report failed for w1:p[14]' "$(state agent-priority.log)")"

# Singleton: while another ticker holds the lock, a start exits without writing.
setup
seed_snooze w1:p1 600 30
exec 7>"$(state agent-snooze.ticker.lock)"
flock -n 7
ticker_once
exec 7>&-
check "a second ticker writes nothing" "" "$(cat "$FIXTURE_DIR/metadata.log")"
check "a second ticker says why it left" "yes" \
  "$(grep -qF 'ticker: already running' "$(state agent-priority.log)" && echo yes || echo no)"

# Handoff: the probe records, from inside the store critical section at the
# end of the pass, whether each lock is held right then.
setup
mkdir -p "$(dirname "$(state agent-snooze)")"
AGENT_PRIORITY_TICK_ONCE=1 AGENT_PRIORITY_TICK_PROBE="$T/probe" sh "$SCRIPT" ticker || true
check "nothing snoozed: singleton released while the store lock is still held" \
  "ticker=free store=held" "$(cat "$T/probe" 2>/dev/null)"

setup
seed_snooze w1:p1 600 30
AGENT_PRIORITY_TICK_ONCE=1 AGENT_PRIORITY_TICK_PROBE="$T/probe" sh "$SCRIPT" ticker || true
check "something snoozed: the pass keeps the singleton" \
  "ticker=held store=held" "$(cat "$T/probe" 2>/dev/null)"

# Ticker writes under the store lock. The ticker reads early and reports late
# (0.6s delay); the off press reads and clears inside that window (0.2s).
# Unlocked, the ticker's stale "zz" lands after the clear; locked, either
# order ends on the clear.
setup
seed_snooze w1:p1 600 240
( AGENT_PRIORITY_CRIT_DELAY=0.6 AGENT_PRIORITY_TICK_ONCE=1 sh "$SCRIPT" ticker || true ) &
( AGENT_PRIORITY_CRIT_DELAY=0.2 sh "$SCRIPT" snooze w1:p1 || true ) &
wait
check "a concurrent tick never leaves a stale label after an off press" \
  "pane report-metadata w1:p1 --source agent-snooze --clear-token snz" \
  "$(snz_lines w1:p1 | tail -n1)"
check "and the store agrees: no snooze for w1:p1" "" \
  "$(awk -F'\t' '$1 == "w1:p1"' "$(state agent-snooze)")"
```

What each distinguishes:
- *refreshes / NhMm / 5m / 1h5m / 4h*: missing ticker; floor instead of ceil (`9m`, `4m`, `1h4m`, `3h59m`); a formatter that always prints minutes (`4h0m`).
- *clears a label whose snooze expired*: a reconcile driven by the snooze snapshot (which `snoozes_active` has already stripped of the expired w1:p2 line) instead of the agent list's token.
- *gone pane / no label*: reporting from the store without joining on live agents; clearing every agent unconditionally.
- *TTL ≤ 20000*: the fixed `90000` without the clamp.
- *failed tick write*: a report failure aborting the pass under `set -e` (count 1, or exit 1).
- *second ticker*: no singleton; a singleton check that runs after the first write.
- *handoff, nothing snoozed → `ticker=free store=held`*: releasing the singleton only after `locked` returns (probe reads `ticker=held`), or not at all. **Something snoozed → `ticker=held store=held`**: a pass that always releases. `store=held` in both proves the probe runs inside the critical section, not after it.
- *concurrent tick*: `tick_pass` running outside `locked` — the 0.6 s ticker read happens before the 0.2 s off press's clear and its report after it, so the last line is a `--token snz=zz …` report.

- [ ] **Step 2: Run to see them fail for the stated reasons**

Run: `sh ~/dotfiles/tests/herdr-agent-priority/test.sh 2>/dev/null | grep -A2 FAIL`
Expected: the new checks FAIL because the script dies with `unknown command: ticker` (the exit-code check reads `2`) — except five that a do-nothing ticker satisfies and that therefore pass vacuously now: "writes nothing for a gone pane", "…no snooze and no label", "a second ticker writes nothing", and both concurrent checks (the last line is the off press's own clear when no ticker writes at all). Step 6 is the proof for the concurrent and handoff checks.

- [ ] **Step 3: Implement**

After `ensure_ticker()`:

```sh
# THE TICKER. One background process refreshes every snooze label once a
# minute while anything is snoozed, and exits when nothing is. Nothing tracks
# PIDs: it holds `flock -n` on $TICKER_LOCK (fd 8) for its lifetime, and a
# start that finds that taken exits at once.
#
# EXIT/START HANDOFF. The race: a ticker decides to exit, a new snooze starts
# a replacement, the replacement finds the singleton still held and leaves,
# then the old ticker exits — and the new snooze has no updater. Closed by
# taking both decisions under the store lock: the ticker releases fd 8 at the
# end of its pass, *inside* the critical section, when it found nothing
# snoozed; `snooze` writes its line inside its own critical section and starts
# a ticker only after releasing the lock. Either the pass ran first (fd 8 is
# already free when the replacement asks) or the snooze did (the pass sees the
# new line and keeps running; the replacement correctly leaves).
ticker_release() { exec 8>&-; ticker_exit=1; }

# Test seam: record, from inside the critical section, whether the singleton
# and the store lock are held right now. A fresh open conflicts with a lock
# this process holds on another descriptor, so `flock -n` on the path answers
# exactly that. Unset in normal use.
tick_probe() {
  [ -n "${AGENT_PRIORITY_TICK_PROBE:-}" ] || return 0
  t=held
  flock -n "$TICKER_LOCK" true 2>/dev/null && t=free
  s=held
  flock -n "$LOCK" true 2>/dev/null && s=free
  printf 'ticker=%s store=%s\n' "$t" "$s" >>"$AGENT_PRIORITY_TICK_PROBE"
}

# One pass, run under `locked` so it can never publish a label that a
# `snooze` press has since changed: the press either finished before this pass
# (the fresh reads below see it) or waits for the pass and overwrites it.
#
# Whether to keep running is decided by the STORE, not the agent list: with
# herdr down the list fails every pass, and a ticker that waited for it would
# never exit. With the store deciding, it stops within 4 h (the longest rung)
# whatever herdr does.
tick_pass() {
  active=$(snoozes_active) || {
    log "tick: snooze read failed, stopping"
    ticker_release
    return 0
  }
  agents=''
  if alist=$(herdr agent list); then
    agents=$(printf '%s\n' "$alist" |
      jq -r '.result.agents[] | "\(.pane_id)\t\(.tokens.snz // "")"' 2>/dev/null) || agents=''
  fi
  if [ -z "$agents" ]; then
    log "tick: agent list unavailable, no labels this pass"
  else
    crit_delay
    printf '%s\n' "$agents" |
      while IFS='	' read -r pane cur; do
        [ -n "$pane" ] || continue
        wake=$(printf '%s\n' "$active" | awk -F'\t' -v p="$pane" '$1 == p { print $2; exit }')
        if [ -n "$wake" ]; then
          snz_report "$pane" "$wake" tick
        elif [ -n "$cur" ]; then
          # Expired, switched off or edited away, but still on screen. Driven
          # by the token because $active has already lost expired lines.
          snz_clear "$pane" tick
        fi
      done
  fi
  [ -n "$active" ] || ticker_release
  tick_probe
}
```

New case, before `*)`:

```sh
ticker)
  # Started detached by ensure_ticker; see the THE TICKER comment above.
  # A pass right away (so a restart's labels come back at once), then one a
  # minute. Each pass opens and closes fd 9 through `locked`, so between
  # passes it holds no store lock.
  exec 8>"$TICKER_LOCK"
  flock -n 8 || { log "ticker: already running"; exit 0; }
  log "ticker: started"
  while :; do
    ticker_exit=''
    locked tick_pass
    if [ -n "$ticker_exit" ]; then
      log "ticker: nothing snoozed, stopping"
      exit 0
    fi
    # Test seam: exactly one pass.
    [ -z "${AGENT_PRIORITY_TICK_ONCE:-}" ] || exit 0
    # 8>&-: a child that inherited fd 8 keeps the singleton after the ticker
    # dies (measured), so if this shell is killed mid-wait, a sleeping child
    # must not block the replacement for up to a minute.
    sleep 60 8>&-
  done
  ;;
```

Add to the header usage comment, after the `list` line:

```sh
#   herdr-agent-priority.sh ticker            refresh snooze labels once a minute (started by snooze/stamp)
```

Properties: `tick_pass` is only ever run via `locked`; fd 8 is released inside it; the ticker's `exit` decision reads `ticker_exit`, which only `ticker_release` sets.

- [ ] **Step 4: Run the suite**

Run: `sh ~/dotfiles/tests/herdr-agent-priority/test.sh 2>/dev/null | grep -c '^ok'; sh ~/dotfiles/tests/herdr-agent-priority/test.sh 2>/dev/null | grep FAIL || echo no-fails`
Expected: `81`, `no-fails` (64 + 17).

- [ ] **Step 5: Syntax check**

Run: `sh -n ~/dotfiles/terminal/.config/herdr/herdr-agent-priority.sh && echo ok` → `ok`.

- [ ] **Step 6: Prove the lock and handoff checks can fail**

(a) Change the ticker loop's `locked tick_pass` to plain `tick_pass`. Rerun: "a concurrent tick never leaves a stale label" must FAIL (last line is a `--token snz=zz 10m …` report); both handoff checks read `store=free` and FAIL. Revert.
(b) Move `[ -n "$active" ] || ticker_release` out of `tick_pass` to just after `locked tick_pass` in the loop (still before the exit check). Rerun: "singleton released while the store lock is still held" must FAIL — the probe, still inside the pass, reads `ticker=held`. Revert; rerun: all ok.

- [ ] **Step 7: Commit**

```bash
cd ~/dotfiles
git add terminal/.config/herdr/herdr-agent-priority.sh tests/herdr-agent-priority/test.sh
git commit -m "herdr: snooze ticker - one pass a minute under the store lock, singleton with in-lock handoff

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013eVjtaWhwxCpkrmZkWssH1"
```

---

### Task 5 (ticker branch): `prune` clears stale labels; `stamp` ensures the ticker

**Files:**
- Modify: `terminal/.config/herdr/herdr-agent-priority.sh` — end of `prune()` (~line 323–332), the `stamp)` case (~751–756)
- Test: `tests/herdr-agent-priority/test.sh`

- [ ] **Step 1: Write the failing tests**

Add a block after "stamp reconciles prisort only where it is wrong":

```sh
# --- stamp and the snooze label (Task 5) -------------------------------------------
setup
set_snz w1:p2 "zz 3m"
seed_snooze w1:p1 600 30
set_snz w1:p1 "zz 10m"
run stamp
check "stamp clears a label with no snooze behind it" \
  "pane report-metadata w1:p2 --source agent-snooze --clear-token snz" \
  "$(snz_lines w1:p2)"
check "stamp leaves a label whose snooze is active alone" "" "$(snz_lines w1:p1)"
check "stamp starts the ticker when something is snoozed" \
  "args=[-f $HOME/.config/herdr/herdr-agent-priority.sh ticker]" \
  "$(sed -n 1p "$FIXTURE_DIR/setsid.log" | sed 's/ fds=.*//')"
check "stamp starts the ticker with fd 9 closed" "no" "$(fd9_in 1)"

setup
run stamp
check "stamp starts no ticker when nothing is snoozed" "" "$(cat "$FIXTURE_DIR/setsid.log")"

# A clear that failed is repaired by the next stamp.
setup
seed_snooze w1:p1 600 240
set_snz w1:p1 "zz 10m"
HERDR_STUB_FAIL_SNOOZE_META=1 sh "$SCRIPT" snooze w1:p1 2>/dev/null || true
check "precondition: the off press's clear failed" "" "$(snz_lines w1:p1)"
run stamp
check "the next stamp issues the clear the off press lost" \
  "pane report-metadata w1:p1 --source agent-snooze --clear-token snz" \
  "$(snz_lines w1:p1)"
```

And make the existing pane-list-failure loop discriminate for labels too: inside `for mode in exit errjson empty; do`, after `setup`, add

```sh
  set_snz w1:p2 "zz 3m"
```

so a label reconcile placed ahead of the guard would write (and "writes no metadata" would catch it).

What each distinguishes: a `prune` with no label reconcile; one that clears every label (w1:p1 would get a clear); no ticker start from `stamp`, or a start inside `locked prune` (fd 9); an unconditional start on every `stamp` (it fires on every `pane.agent_detected`); and the failed-clear → recovery path (spec test 6), where the precondition check proves the clear really was lost.

- [ ] **Step 2: Run to see them fail**

Expected FAILs: "clears a label with no snooze behind it" (empty), "starts the ticker when something is snoozed" (empty), "issues the clear the off press lost" (empty). The fd-9, "no ticker when nothing is snoozed", "leaves … alone" and precondition checks pass vacuously now.

- [ ] **Step 3: Implement**

At the end of `prune()`, after the prisort reconcile loop (after its closing `done`):

```sh

  # A label can outlive its snooze: a clear failed, or the snooze expired and
  # nothing has ticked since. Clear every live label with no active snooze
  # behind it. Driven by the agent list's tokens, not the store, because
  # $active has already lost expired lines. Active labels are the ticker's.
  printf '%s\n' "$alist" |
    jq -r '.result.agents[] | select((.tokens.snz // "") != "") | .pane_id' |
    while read -r pane; do
      [ -n "$pane" ] || continue
      printf '%s\n' "$active" | cut -f1 | grep -qxF "$pane" || snz_clear "$pane" prune
    done
```

In the `stamp)` case, after `set_view`:

```sh
  # After the lock, never inside it. Cheap to skip: this hook fires on every
  # pane.agent_detected, and most of the time nothing is snoozed.
  snoozed_now=$(snoozes_active) || snoozed_now=''
  [ -z "$snoozed_now" ] || ensure_ticker
```

Property: the clear runs inside `locked prune` (so after the pane-list guard); the ticker start is outside it.

- [ ] **Step 4: Run the suite**

Expected: `88`, `no-fails` (81 + 7).

- [ ] **Step 5: Prove the recovery test can fail**

Comment out the new `prune` block. Rerun: "the next stamp issues the clear the off press lost" and "stamp clears a label with no snooze behind it" FAIL. Restore; rerun: all ok.

- [ ] **Step 6: Commit**

```bash
cd ~/dotfiles
git add terminal/.config/herdr/herdr-agent-priority.sh tests/herdr-agent-priority/test.sh
git commit -m "herdr: stamp clears orphaned snooze labels and starts the ticker when anything is snoozed

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013eVjtaWhwxCpkrmZkWssH1"
```

---

### Task 4F (fallback branch only — replaces Tasks 4 and 5): `prune` re-reports and clears labels

No ticker. The label is `zz HH:MM` with a TTL to the wake, so it disappears on time by itself; `prune` (every `stamp`: startup and each `pane.agent_detected`) re-reports labels a restart wiped and clears ones that outlived their snooze.

**Files:**
- Modify: `terminal/.config/herdr/herdr-agent-priority.sh` — end of `prune()`
- Test: `tests/herdr-agent-priority/test.sh`

- [ ] **Step 1: Write the failing tests** (after "stamp reconciles prisort only where it is wrong")

```sh
# --- stamp and the snooze label (Task 4F) ------------------------------------------
setup
seed_snooze w1:p1 600 30
wake=$(awk -F'\t' '$1 == "w1:p1" { print $2 }' "$(state agent-snooze)" 2>/dev/null || true)
run stamp
check "stamp restores a label a restart wiped" "yes" \
  "$(snz_lines w1:p1 | grep -qF -- "--token snz=zz $(date -d "@$wake" +%H:%M) --ttl-ms " && echo yes || echo no)"

setup
seed_snooze w1:p1 600 30
wake=$(awk -F'\t' '$1 == "w1:p1" { print $2 }' "$(state agent-snooze)" 2>/dev/null || true)
set_snz w1:p1 "zz $(date -d "@$wake" +%H:%M)"
run stamp
check "stamp leaves a correct label alone" "" "$(snz_lines w1:p1)"

setup
set_snz w1:p2 "zz 14:30"
run stamp
check "stamp clears a label with no snooze behind it" \
  "pane report-metadata w1:p2 --source agent-snooze --clear-token snz" "$(snz_lines w1:p2)"

setup
seed_snooze w1:p1 600 240
set_snz w1:p1 "zz 14:30"
HERDR_STUB_FAIL_SNOOZE_META=1 sh "$SCRIPT" snooze w1:p1 2>/dev/null || true
check "precondition: the off press's clear failed" "" "$(snz_lines w1:p1)"
run stamp
check "the next stamp issues the clear the off press lost" \
  "pane report-metadata w1:p1 --source agent-snooze --clear-token snz" "$(snz_lines w1:p1)"

setup
seed_snooze w1:p1 600 30
run stamp
check "no ticker is ever started" "" "$(cat "$FIXTURE_DIR/setsid.log")"
```

Also add `set_snz w1:p2 "zz 3m"` after `setup` inside the pane-list-failure loop (as in Task 5).

Distinguishes: no re-report after restart; re-reporting on every stamp even when correct (a report per active snooze per `agent_detected`); no clear; the failed-clear recovery; any ticker start.

- [ ] **Step 2: Run to see them fail** — "restores a label", "clears a label", "issues the clear" FAIL (empty).

- [ ] **Step 3: Implement** — at the end of `prune()`:

```sh

  # Labels, without a ticker: re-report any active snooze whose label is not
  # what it should be (a restart wiped it), with the TTL recomputed to the
  # time left, and clear any label with no active snooze behind it (a clear
  # failed, or it was hand-edited). Driven by the agent list's tokens.
  printf '%s\n' "$alist" |
    jq -r '.result.agents[] | "\(.pane_id)\t\(.tokens.snz // "")"' |
    while IFS='	' read -r pane cur; do
      [ -n "$pane" ] || continue
      wake=$(printf '%s\n' "$active" | awk -F'\t' -v p="$pane" '$1 == p { print $2; exit }')
      if [ -n "$wake" ]; then
        [ "$cur" = "zz $(date -d "@$wake" +%H:%M)" ] || snz_report "$pane" "$wake" prune
      elif [ -n "$cur" ]; then
        snz_clear "$pane" prune
      fi
    done
```

- [ ] **Step 4: Run the suite** — Expected: `69`, `no-fails` (63 from Task 3-fallback + 6).
- [ ] **Step 5: Prove it can fail** — comment out the block; "restores a label" and both clear checks FAIL; restore.
- [ ] **Step 6: Commit** — `git add` the script and `test.sh`; message `herdr: stamp restores and clears snooze labels (no ticker)` with the two trailer lines.

---

### Task 6: Sidebar templates, docs, and the live check (human)

**Files:**
- Modify: `terminal/.config/herdr/config.toml:473-486` (comment + both row templates)
- Modify: `terminal/.config/herdr/README.md` (§ The picker's last line, § How it is wired)

- [ ] **Step 1: Templates**

In `config.toml` replace

```toml
[ui.sidebar.agents]
rows = [["state_icon", "$idx", "$pri", "workspace", "tab"], ["agent"]]

[ui.sidebar.agents.rows_by_agent]
claude = [
  ["state_icon", "$idx", "$pri", { token = "workspace", dim = true }],
  ["terminal_title_stripped"],
]
```

with

```toml
[ui.sidebar.agents]
rows = [["state_icon", "$idx", "$pri", { token = "$snz", dim = true }, "workspace", "tab"], ["agent"]]

[ui.sidebar.agents.rows_by_agent]
claude = [
  ["state_icon", "$idx", "$pri", { token = "$snz", dim = true }, { token = "workspace", dim = true }],
  ["terminal_title_stripped"],
]
```

and extend the comment above `[ui.sidebar.agents]` (after "…so unranked agents stay clean.") with:

```toml
# $snz is the snooze label, "zz 24m", stamped by the same script under its own
# metadata source (agent-snooze) with a TTL, refreshed once a minute while
# anything is snoozed, and gone when the snooze ends. Dimmed because it is a
# qualifier on the row, not a thing to act on. `dim` on a custom token is
# validated, not ignored: a misspelt style key fails `herdr config check`.
```

(Fallback branch: say `"zz 14:30", its wake time,` and "removed by herdr at the wake" instead of "refreshed once a minute".)

- [ ] **Step 2: Validate**

Run: `herdr config check`
Expected: `config: ok`. (Read-only.)

- [ ] **Step 3: README**

In § The picker, replace the last line with:

```markdown
Snoozed rows show `zz HH:MM`, their wake time, dimmed and last in their rank.
In the sidebar they show the time left instead, `zz 24m`, next to the rank.
```

(Fallback: the sidebar shows the wake time too.)

In § How it is wired, add a table row after `agent-priority.lock`:

```markdown
| `~/.local/state/herdr/agent-snooze.ticker.lock` | Held by the one ticker that refreshes snooze labels. |
```

and after the `$prisort` bullet add:

```markdown
- `$snz` is the snooze label, under its own source `agent-snooze` so its TTL
  can never expire the rank tokens. A single background ticker, started by
  `alt+z` or the startup hook and gone when nothing is snoozed, refreshes it
  once a minute; every label write, the ticker's included, happens under the
  store lock. If the ticker dies the label is gone within 90 s, never wrong.
```

(Fallback: replace that bullet's last three sentences with "It shows the wake time and expires at the wake; `stamp` restores it after a restart.")

Add `ticker` to the "Subcommands, if you need them by hand" list (ticker branch).

- [ ] **Step 4: Commit, then reload**

```bash
cd ~/dotfiles
git add terminal/.config/herdr/config.toml terminal/.config/herdr/README.md
git commit -m "herdr: show the snooze label (\$snz) in both sidebar row templates; docs

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013eVjtaWhwxCpkrmZkWssH1"
herdr server reload-config
```

- [ ] **Step 5: HUMAN live check** — ask the user to do each and report; run the read-only agent checks alongside.

1. Press `alt+z` on an agent. Expected: `zz 5m`, dimmed, appears next to the rank at once.
   Agent: `pgrep -af 'herdr-agent-priority.sh ticker'` → exactly one line (ticker branch).
2. Leave it 3+ minutes. Expected: `zz 4m`, `zz 3m`, … — it never blinks out. (A gap would mean a re-report does not reset the TTL.) Agent: `herdr agent list | jq -r '.result.agents[] | select(.tokens.snz) | "\(.pane_id) \(.tokens.snz)"'` once a minute.
3. Snooze a second agent. Expected: still one ticker.
4. Press `alt+z` through to off on both. Expected: each label goes at once; within 60 s `pgrep` prints nothing and the log ends with `ticker: nothing snoozed, stopping` (`tail -n5 ~/.local/state/herdr/agent-priority.log`).
5. Rank changes (`alt+p`) still show `P4` etc. and never vanish after 90 s.
6. **Deferred to the user's next natural herdr restart** (a restart exits pane processes — never trigger one for this): with a snooze active, after the restart the label is back within seconds (startup `stamp` → ticker's first pass). This is also the live proof that a ticker started from the **startup hook** survives. Record the outcome in the spec's Result paragraph when it happens.

Fallback branch: 1 shows `zz HH:MM`; 2 becomes "the label stays until the wake time, then vanishes by itself"; skip the `pgrep` lines; 6 checks the label returns after restart via `stamp`.

---

# Part 2 — publish as a herdr plugin (`~/Source/herdr-agent-priority`)

### Task 7: Create the repo and import the files unchanged

**Files:** create everything under `~/Source/herdr-agent-priority/` listed in the File map except `README.md`, `LICENSE`, `.github/`, `tests/bin/fzf`.

- [ ] **Step 1: Create and copy**

```bash
mkdir -p ~/Source/herdr-agent-priority/tests/bin
cd ~/Source/herdr-agent-priority
git init -b main
cp -p ~/dotfiles/terminal/.config/herdr/herdr-agent-priority.sh agent-priority.sh
cp -p ~/dotfiles/terminal/.config/herdr/plugins/agent-priority/herdr-plugin.toml herdr-plugin.toml
cp -p ~/dotfiles/tests/herdr-agent-priority/test.sh ~/dotfiles/tests/herdr-agent-priority/agents.json tests/
cp -p ~/dotfiles/tests/herdr-agent-priority/bin/* tests/bin/
ls -l agent-priority.sh tests/bin
```
Expected: `agent-priority.sh` and every `tests/bin/*` are `-rwx`.

- [ ] **Step 2: A config for the key-hint tests**

`tests/config.toml` (for now the dotfiles' shell-command form, so the import passes unchanged; Task 10 switches it to the README snippet):

```toml
[keys]
prefix = "alt+space"

[[keys.command]]
key = "prefix+p"
type = "shell"
command = 'sh -c "$HOME/.config/herdr/herdr-agent-priority.sh open"'

[[keys.command]]
key = "alt+shift+p"
type = "shell"
command = 'sh -c "$HOME/.config/herdr/herdr-agent-priority.sh down"'
```

- [ ] **Step 3: Adapt the test paths**

In `tests/test.sh` replace

```sh
REPO=$(cd "$HERE/../.." && pwd)
SCRIPT="$REPO/terminal/.config/herdr/herdr-agent-priority.sh"
CONFIG="$REPO/terminal/.config/herdr/config.toml"
```

with

```sh
REPO=$(cd "$HERE/.." && pwd)
SCRIPT="$REPO/agent-priority.sh"
CONFIG="$HERE/config.toml"
```

and in its header comment `sh tests/herdr-agent-priority/test.sh` → `sh tests/test.sh`, `Offline tests for herdr-agent-priority.sh.` → `Offline tests for agent-priority.sh.`

- [ ] **Step 4: Run**

Run: `cd ~/Source/herdr-agent-priority && sh tests/test.sh 2>/dev/null | grep -c '^ok'; sh tests/test.sh 2>/dev/null | grep FAIL || echo no-fails`
Expected: the same count as the final Part-1 run (`88` ticker branch / `69` fallback), `no-fails`. The script is unchanged, so any FAIL here is a path mistake in Step 3.

- [ ] **Step 5: Commit**

```bash
cd ~/Source/herdr-agent-priority
git add agent-priority.sh herdr-plugin.toml tests
git ls-files -s agent-priority.sh
git commit -m "Import agent-priority from dotfiles

The script, manifest and offline suite as they stood in
DanielThyselius/dotfiles; history is not carried over.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013eVjtaWhwxCpkrmZkWssH1"
```
Expected from `ls-files -s`: mode `100755`.

---

### Task 8: Paths from the plugin environment — `SELF`, `STATE_DIR`, the socket

**Files:**
- Modify: `agent-priority.sh` — `STATE_DIR` (line ~67), `SELF` (line ~564), `set_view` python (line ~355)
- Create: `tests/bin/fzf`
- Modify: `tests/test.sh` — `setup`, `state()`, every `mkdir -p "$XDG_STATE_HOME/herdr"`, new block

- [ ] **Step 1: Stub fzf**

`tests/bin/fzf` (chmod +x):

```sh
#!/bin/sh
# Stub fzf: record every argument on its own line — so tests can read the
# picker's real --bind strings — swallow the rows, and exit like an
# interrupted fzf (130), i.e. no choice.
for a in "$@"; do printf '%s\n' "$a"; done >"$FIXTURE_DIR/fzf.args"
cat >/dev/null
exit 130
```

- [ ] **Step 2: Move the harness to the new state location (this is the failing test for `STATE_DIR`)**

```bash
cd ~/Source/herdr-agent-priority
sed -i 's|printf '"'"'%s/herdr/%s'"'"'|printf '"'"'%s/herdr-agent-priority/%s'"'"'|' tests/test.sh
sed -i 's|mkdir -p "\$XDG_STATE_HOME/herdr"$|mkdir -p "$XDG_STATE_HOME/herdr-agent-priority"|' tests/test.sh
grep -n 'XDG_STATE_HOME/herdr"\|%s/herdr/%s' tests/test.sh || echo none-left
```
Expected: `none-left`. `state()` now reads `printf '%s/herdr-agent-priority/%s' "$XDG_STATE_HOME" "$1"`.

In `setup()`, add `HERDR_PLUGIN_ROOT HERDR_PLUGIN_STATE_DIR HERDR_PLUGIN_CONFIG_DIR HERDR_PLUGIN_ID` to the `unset HERDR_SOCKET_PATH …` list, and `: >"$FIXTURE_DIR/fzf.args"` after the other log resets.

The two ticker-start expectations from Tasks 3 and 5 name the old `SELF`; they become `SELF` tests for the no-`HERDR_PLUGIN_ROOT` case (exact, because `setup` unsets it) — ticker branch only:

```bash
sed -i 's|args=\[-f $HOME/.config/herdr/herdr-agent-priority.sh ticker\]|args=[-f $REPO/agent-priority.sh ticker]|' tests/test.sh
grep -c 'args=\[-f \$REPO/agent-priority.sh ticker\]' tests/test.sh
```
Expected: `2`.

- [ ] **Step 3: New tests** (block before the harness self-checks)

```sh
# --- plugin environment (Task 8) -------------------------------------------------
setup
HERDR_PLUGIN_STATE_DIR="$T/pstate" sh "$SCRIPT" up w1:p2 || true
check "state goes to HERDR_PLUGIN_STATE_DIR when herdr sets it" "w1:p2	4" \
  "$(cat "$T/pstate/agent-priority" 2>/dev/null)"
check "and nothing is written to the fallback then" "no" \
  "$([ -e "$XDG_STATE_HOME/herdr-agent-priority" ] && echo yes || echo no)"

setup
mkdir -p "$XDG_STATE_HOME/herdr"
printf 'w1:p1\t5\n' >"$XDG_STATE_HOME/herdr/agent-priority"   # the old rank FILE
run up w1:p2
check "the fallback never collides with the old rank file" "w1:p2	4" "$(cat "$(state agent-priority)")"

setup
HERDR_PLUGIN_ROOT="$T/root" sh "$SCRIPT" pick || true
check "SELF comes from HERDR_PLUGIN_ROOT" "yes" \
  "$(grep '^--bind=alt-1:' "$FIXTURE_DIR/fzf.args" | grep -qF "$T/root/agent-priority.sh" && echo yes || echo no)"

setup
( cd "$REPO" && sh ./agent-priority.sh pick ) || true
check "without HERDR_PLUGIN_ROOT, SELF is this script's absolute path" "yes" \
  "$(grep '^--bind=alt-1:' "$FIXTURE_DIR/fzf.args" | grep -qF "$REPO/agent-priority.sh" && echo yes || echo no)"

# set_view talks to $HERDR_SOCKET_PATH. One foreground python binds the socket,
# runs `view` as a child, answers it, and prints the method it received.
setup
method=$(python3 - "$T/view.sock" "$SCRIPT" <<'PY' 2>/dev/null || true
import json, os, socket, subprocess, sys
path, script = sys.argv[1], sys.argv[2]
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path); srv.listen(1); srv.settimeout(5)
child = subprocess.Popen(["sh", script, "view"], env={**os.environ, "HERDR_SOCKET_PATH": path})
conn, _ = srv.accept()
data = conn.recv(65536)
conn.sendall(b'{"id":"agent-priority:view","result":{}}\n')
conn.close(); child.wait(5)
print(json.loads(data)["method"])
PY
)
check "set_view connects to HERDR_SOCKET_PATH" "agent.view.set" "$method"
```

What each distinguishes (plus the two rewritten ticker-start checks, which now FAIL with the old `~/.config/herdr/…` path): a `STATE_DIR` ignoring `HERDR_PLUGIN_STATE_DIR`; a fallback inside `…/state/herdr/` (the `mkdir -p` on an existing file fails and nothing is written); `SELF` still hardcoded to `~/.config/herdr/…`; `SELF` built from a bare `dirname "$0"` (`./agent-priority.sh`, relative — breaks when fzf or setsid runs it from another cwd); `set_view` still dialling `~/.config/herdr/herdr.sock` (with the test's fake `HOME` nothing is there, `accept` times out, `method` is empty).

These assertions are quote-agnostic on purpose: Task 9 wraps `SELF` in single quotes.

- [ ] **Step 4: Run to see them fail**

Expected: most of the existing suite now FAILs (the script still writes `…/state/herdr/`, the harness reads `…/state/herdr-agent-priority/`) — that is the `STATE_DIR` test. The new checks FAIL too: the plugin-dir one (nothing at `$T/pstate`), the collision one (the old script adopts the pre-existing file as its store, and the harness finds nothing at the new path), both `SELF` ones (`~/.config/herdr/…` in the bind), and the socket one after a 5 s `accept` timeout. After the change, the collision check is what catches a fallback of `…/state/herdr/agent-priority/` (a directory where a file already is: `mkdir -p` fails and the script exits under `set -e`).

- [ ] **Step 5: Implement**

Replace `STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr"` with:

```sh
# State lives where herdr says: HERDR_PLUGIN_STATE_DIR is set for every plugin
# command (startup, events, actions, the picker pane) and is
# ${XDG_STATE_HOME:-~/.local/state}/herdr/plugins/agent-priority. The fallback,
# for a hand run from a plain shell, is a directory of its own — never inside
# …/state/herdr/, where agent-priority is the pre-plugin rank FILE and a
# directory of that name could not be created.
STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-agent-priority}"
```

Replace `SELF="$HOME/.config/herdr/herdr-agent-priority.sh"` with:

```sh
# This script, as an absolute path, for the picker's fzf binds and the
# ticker start. herdr sets HERDR_PLUGIN_ROOT for plugin commands; a hand run
# resolves its own directory (absolute, so a different cwd cannot break it).
SELF="${HERDR_PLUGIN_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)}/agent-priority.sh"
```

(`CDPATH=''`: with CDPATH set, `cd` prints the directory it chose, and the substitution would capture it twice.)

In `set_view`'s python, replace `path = os.path.expanduser("~/.config/herdr/herdr.sock")` with:

```python
# The session's socket: herdr injects HERDR_SOCKET_PATH into every plugin
# command, and a named session or an isolated XDG_CONFIG_HOME puts it
# somewhere else than the default. Default mirrors herdr's own:
# <XDG_CONFIG_HOME or ~/.config>/herdr/herdr.sock.
path = os.environ.get("HERDR_SOCKET_PATH") or os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
    "herdr", "herdr.sock")
```

Update the header comment's example paths `herdr-agent-priority.sh` → `agent-priority.sh` (lines 4–15, and the ticker line).

Properties: `STATE_DIR` never resolves inside `…/state/herdr/` unless herdr says so; `SELF` is absolute; `set_view` never reaches a socket other than the one in the environment when one is set.

- [ ] **Step 6: Run the suite** — Expected: `94`, `no-fails` (88 + 6; fallback branch `75` = 69 + 6).
- [ ] **Step 7: Commit** — `git add agent-priority.sh tests/test.sh tests/bin/fzf`; message `Paths from the plugin environment: SELF, STATE_DIR, HERDR_SOCKET_PATH` + trailers.

---

### Task 9: Shell-safe picker commands

**Files:** Modify `agent-priority.sh` (new `shq` near `die`, the `pick)` case lines ~700–713); `tests/test.sh`.

- [ ] **Step 1: The failing test** — runs the picker's *real* bind strings through `sh -c` from a checkout whose path has a space and a single quote:

```sh
# --- picker binds survive a path with spaces and quotes (Task 9) --------------------
setup
P="$T/My Plugins/Dan's/herdr-agent-priority"
mkdir -p "$P"
cp -p "$SCRIPT" "$P/agent-priority.sh"   # -p: the binds exec the file directly
HERDR_PLUGIN_ROOT="$P" sh "$P/agent-priority.sh" pick || true
check "the picker pins its child shell to sh" "yes" \
  "$(grep -qx -- "--with-shell=sh -c" "$FIXTURE_DIR/fzf.args" && echo yes || echo no)"
bind=$(grep '^--bind=alt-5:' "$FIXTURE_DIR/fzf.args" | sed 's/^--bind=alt-5://')
exe=$(printf '%s\n' "$bind" | sed -n 's/^execute-silent(\(.*\))+reload(.*)$/\1/p' | sed "s/{1}/'w1:p2'/")
rel=$(printf '%s\n' "$bind" | sed -n 's/^execute-silent(.*)+reload(\(.*\))$/\1/p')
sh -c "$exe" 2>/dev/null || true
check "alt-5's execute command runs from a spaced, quoted path" "w1:p2	5" "$(cat "$(state agent-priority)" 2>/dev/null)"
check "alt-5's reload command lists the rows" "yes" \
  "$(sh -c "$rel" 2>/dev/null | cut -f1 | grep -qx 'w1:p2' && echo yes || echo no)"
```

(`{1}` is replaced by `'w1:p2'` because that is how fzf substitutes a field: single-quoted.)

Distinguishes: unquoted `$SELF` (`sh -c` tries to run `…/My` and the store stays empty); quoting that does not escape the embedded `'` (a syntax error); no `--with-shell` (with `$SHELL=fish` a POSIX quote idiom could be read differently).

- [ ] **Step 2: Run** — the three checks FAIL (no `--with-shell`; empty store; empty rows).

- [ ] **Step 3: Implement** — after `die()`:

```sh
# Single-quote a string for a POSIX shell: wrap it in '…' and turn each
# embedded ' into '\''. For $SELF inside fzf's bind strings, which fzf hands
# to `sh -c` (pinned below with --with-shell).
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
```

In `pick)`, before `sel=$(rows | fzf \`: `q=$(shq "$SELF")`. Add `--with-shell='sh -c' \` as the first fzf option, and replace every `$SELF` inside the `--bind=` strings with `$q`, e.g.

```sh
    --bind="alt-1:execute-silent($q set 1 {1})+reload($q rows)" \
```

(all eight: alt-1..5, alt-p, alt-P, alt-z). Add to the `pick` comment:

```sh
  # $SELF is single-quoted into every bind (shq), and fzf's child shell is
  # pinned to sh, so a checkout under "My Plugins/" works whatever $SHELL is.
  # A path containing ')' still would not: fzf(1) warns that parentheses in an
  # action argument can break its parser.
```

- [ ] **Step 4: Run the suite** — `97` (fallback `78`), `no-fails`.
- [ ] **Step 5: Commit** — `Picker: shell-quote SELF in fzf binds and pin fzf's child shell to sh` + trailers.

---

### Task 10: `keybind_for` finds `plugin_action` bindings

**Files:** Modify `agent-priority.sh` `keybind_for` python (lines ~132–148); `tests/config.toml`; `tests/test.sh`.

- [ ] **Step 1: Switch the hint tests' config to the plugin form (the failing test)**

Replace `tests/config.toml` with (lines 4 onward are the README keys snippet, byte-for-byte — Task 11 enforces that):

```toml
[keys]
prefix = "alt+space"

[[keys.command]]
key = "alt+p"
type = "plugin_action"
command = "agent-priority.up"
description = "Raise agent priority"

[[keys.command]]
key = "alt+shift+p"
type = "plugin_action"
command = "agent-priority.down"
description = "Lower agent priority"

[[keys.command]]
key = "alt+z"
type = "plugin_action"
command = "agent-priority.snooze"
description = "Snooze agent (5m/30m/2h/4h/off)"

[[keys.command]]
key = "alt+g"
type = "plugin_action"
command = "agent-priority.goto"
description = "Go to the top-ranked waiting agent"

[[keys.command]]
key = "prefix+p"
type = "plugin_action"
command = "agent-priority.open"
description = "Ranked agent picker"
```

Add near-miss and legacy tests after the two existing goto-hint tests:

```sh
setup
fixture '.result.agents |= map(select(.pane_id != "w1:p4")
                               | .focused = (.pane_id == "w1:p1"))'
cat >"$T/near.toml" <<'TOML'
[keys]
prefix = "alt+space"
[[keys.command]]
key = "alt+shift+p"
type = "plugin_action"
command = "agent-priority.downer"
[[keys.command]]
key = "prefix+p"
type = "plugin_action"
command = "other-plugin.open"
[[keys.command]]
key = "alt+x"
type = "shell"
command = "agent-priority.down"
TOML
HERDR_CONFIG_PATH="$T/near.toml" sh "$SCRIPT" goto || true
check "near-miss bindings give no hint" "-- Top of the ranking alpha" \
  "$(sed 's/.* -- /-- /' "$FIXTURE_DIR/toasts.log")"

setup
fixture '.result.agents |= map(select(.pane_id != "w1:p4")
                               | .focused = (.pane_id == "w1:p1"))'
cat >"$T/legacy.toml" <<'TOML'
[keys]
prefix = "alt+space"
[[keys.command]]
key = "alt+shift+p"
type = "shell"
command = 'sh -c "$HOME/.config/herdr/herdr-agent-priority.sh down"'
[[keys.command]]
key = "prefix+p"
type = "shell"
command = 'sh -c "/opt/x/agent-priority.sh open"'
TOML
HERDR_CONFIG_PATH="$T/legacy.toml" sh "$SCRIPT" goto || true
check "shell bindings (old and new script name) still give the hint" "yes" \
  "$(grep -qF 'alt+shift+p to lower it · alt+space p to pick another' "$FIXTURE_DIR/toasts.log" && echo yes || echo no)"
```

Distinguishes: no `plugin_action` support (the existing "goto hint names the configured demote and picker keys" now FAILs against the plugin-form config); prefix/substring matching (`agent-priority.downer`, `other-plugin.open`); treating a *shell* command string as an action id (`alt+x`); losing the shell match, or matching only the old name.

- [ ] **Step 2: Run** — "goto hint names the configured…" and "shell bindings (old and new…)" FAIL (the second on `/opt/x/agent-priority.sh`, which the old `herdr-agent-priority\.sh` regex misses).

- [ ] **Step 3: Implement** — in the python, replace the `pat = …` line and the loop with:

```python
# Shell bindings name the script: agent-priority.sh (herdr-agent-priority.sh
# before the plugin move also matches). Plugin bindings name the action.
pat = re.compile(r"agent-priority\.sh\s+" + re.escape(sub) +
                  r"(?=\s|[" + quote_chars + r"]|$)")
action = "agent-priority." + sub
for c in keys.get("command", []):
    cmd = c.get("command", "")
    if c.get("type") == "plugin_action":
        hit = cmd == action
    else:
        hit = bool(pat.search(cmd))
    if hit:
        k = c.get("key", "")
        if k.startswith("prefix+") and keys.get("prefix"):
            k = keys["prefix"] + " " + k[len("prefix+"):]
        print(k)
        break
```

and update the comment above `keybind_for` to mention both forms.

- [ ] **Step 4: Run the suite** — `99` (fallback `80`), `no-fails`.
- [ ] **Step 5: Commit** — `git add agent-priority.sh tests/config.toml tests/test.sh`; `keybind_for: match plugin_action bindings (agent-priority.<sub>)` + trailers.

---

### Task 11: Manifest actions, README, LICENSE, CI

**Files:** Modify `herdr-plugin.toml`; create `README.md`, `LICENSE`, `.github/workflows/test.yml`; `tests/test.sh`.

- [ ] **Step 1: Failing tests** — the manifest and README agree with the tested config:

```sh
# --- manifest and README agree with the tested config (Task 11) ---------------------
# Every plugin_action key in tests/config.toml names an action the manifest
# declares, and that action runs the same subcommand through $HERDR_PLUGIN_ROOT.
check "every bound action exists and runs its subcommand" "ok" "$(python3 - "$REPO/herdr-plugin.toml" "$CONFIG" <<'PY'
import sys, tomllib
man = tomllib.load(open(sys.argv[1], "rb"))
cfg = tomllib.load(open(sys.argv[2], "rb"))
acts = {a["id"]: a["command"] for a in man.get("actions", [])}
bad = []
for c in cfg["keys"]["command"]:
    if c.get("type") != "plugin_action":
        continue
    plugin, _, sub = c["command"].partition(".")
    want = ["sh", "-c", 'exec "$HERDR_PLUGIN_ROOT/agent-priority.sh" ' + sub]
    if plugin != man["id"] or acts.get(sub) != want:
        bad.append(c["command"])
for key in ("startup", "events", "panes"):
    for e in man.get(key, []):
        if "$HERDR_PLUGIN_ROOT/agent-priority.sh" not in e["command"][-1]:
            bad.append(key)
print("ok" if not bad else " ".join(bad))
PY
)"

# The README's keys snippet is exactly what these tests run against.
readme_keys=$(awk '/<!-- keys-snippet -->/ { on = 1; next } on && /^```toml/ { p = 1; next } p && /^```/ { exit } p' "$REPO/README.md" 2>/dev/null || true)
check "README keys snippet == tests/config.toml (minus its [keys] header)" \
  "$(tail -n +4 "$CONFIG")" "$readme_keys"
check "agent-priority.sh is executable in git" "100755" \
  "$(cd "$REPO" && git ls-files -s agent-priority.sh | cut -d' ' -f1)"
```

Distinguishes: a README keybind naming an action the manifest lacks (the "document it, never verify it" gap the spec's Risks call out); a manifest command still pointing at `$HOME/.config/herdr/…`; README and tests drifting; a lost exec bit (herdr and the fzf binds exec the file directly).

- [ ] **Step 2: Run** — first check prints the five missing actions plus `startup events panes`; the README check FAILs (no README).

- [ ] **Step 3: Manifest** — replace `herdr-plugin.toml` with:

```toml
id = "agent-priority"
name = "Agent priority"
version = "2.0.0"
description = "Rank waiting agents 1-5, jump to the top of the ranking, snooze, and pick from a ranked popup"
min_herdr_version = "0.8.2"
platforms = ["linux"]

# Ranks and snooze labels are pane metadata tokens, and herdr rebuilds those as
# empty on session restore, so the startup hook re-projects them from the state
# files. LOOP HAZARD: the script writes back with `pane report-metadata`, which
# fires pane.updated and *.metadata_updated — never hook those.
[[startup]]
command = ["sh", "-c", "exec \"$HERDR_PLUGIN_ROOT/agent-priority.sh\" stamp"]

# A newly detected agent has no sort token yet and would sort below every
# ranked one. stamp only writes where a value is wrong. pane.agent_detected is
# not re-fired by report-metadata, so this is safe.
[[events]]
on = "pane.agent_detected"
command = ["sh", "-c", "exec \"$HERDR_PLUGIN_ROOT/agent-priority.sh\" stamp"]

# The ranked picker. A popup: session-modal, receives every key including
# Escape (fzf needs that), and is not a real pane.
[[panes]]
id = "picker"
title = "Agent priority"
placement = "popup"
width = "80%"
height = "60%"
command = ["sh", "-c", "exec \"$HERDR_PLUGIN_ROOT/agent-priority.sh\" pick"]

# One action per key. Bind them in config.toml with
#   type = "plugin_action", command = "agent-priority.<id>"
[[actions]]
id = "up"
title = "Raise agent priority"
contexts = ["pane"]
command = ["sh", "-c", "exec \"$HERDR_PLUGIN_ROOT/agent-priority.sh\" up"]

[[actions]]
id = "down"
title = "Lower agent priority"
contexts = ["pane"]
command = ["sh", "-c", "exec \"$HERDR_PLUGIN_ROOT/agent-priority.sh\" down"]

[[actions]]
id = "snooze"
title = "Snooze agent (5m/30m/2h/4h/off)"
contexts = ["pane"]
command = ["sh", "-c", "exec \"$HERDR_PLUGIN_ROOT/agent-priority.sh\" snooze"]

[[actions]]
id = "goto"
title = "Go to the top-ranked waiting agent"
contexts = ["global"]
command = ["sh", "-c", "exec \"$HERDR_PLUGIN_ROOT/agent-priority.sh\" goto"]

# `open`, not the picker pane directly: focusing from inside a popup is undone
# as it closes, so this command opens it, waits for the choice, then focuses.
[[actions]]
id = "open"
title = "Ranked agent picker"
contexts = ["global"]
command = ["sh", "-c", "exec \"$HERDR_PLUGIN_ROOT/agent-priority.sh\" open"]
```

- [ ] **Step 4: LICENSE**

```bash
cp ~/Source/omascape/LICENSE ~/Source/herdr-agent-priority/LICENSE
head -3 ~/Source/herdr-agent-priority/LICENSE
```
Expected: `MIT License`, blank, `Copyright (c) 2026 Mindful Stack` (the org's existing wording).

- [ ] **Step 5: README.md**

````markdown
# herdr agent priority

Rank the agents that are waiting on you from 1 to 5, jump to the top of that
ranking, snooze the ones waiting on someone else, and pick from a ranked popup.
A plugin for [herdr](https://herdr.dev) ≥ 0.8.2 (tested on 0.8.2), Linux.

With thirty agents the sidebar tells you *that* several want you, never *which*
to do first, so the day goes to whoever finished last. A number you set once,
when the session starts, lets the work be chosen instead of serviced. Priority
1 work never getting reached is the intent — it is the cue to close it.

## Install

```sh
herdr plugin install Mindful-Stack/herdr-agent-priority
```

Then add the keys below to `~/.config/herdr/config.toml` (anywhere after your
`[keys]` table), add the two tokens to your sidebar rows, and run
`herdr server reload-config`.

<!-- keys-snippet -->
```toml
[[keys.command]]
key = "alt+p"
type = "plugin_action"
command = "agent-priority.up"
description = "Raise agent priority"

[[keys.command]]
key = "alt+shift+p"
type = "plugin_action"
command = "agent-priority.down"
description = "Lower agent priority"

[[keys.command]]
key = "alt+z"
type = "plugin_action"
command = "agent-priority.snooze"
description = "Snooze agent (5m/30m/2h/4h/off)"

[[keys.command]]
key = "alt+g"
type = "plugin_action"
command = "agent-priority.goto"
description = "Go to the top-ranked waiting agent"

[[keys.command]]
key = "prefix+p"
type = "plugin_action"
command = "agent-priority.open"
description = "Ranked agent picker"
```

Sidebar: add `"$pri"` (the rank label) and `{ token = "$snz", dim = true }`
(the snooze label) to the agent rows you already have, for example

```toml
[ui.sidebar.agents]
rows = [["state_icon", "$pri", { token = "$snz", dim = true }, "workspace", "tab"], ["agent"]]
```

Merge these into your existing `[ui.sidebar.agents]` rather than pasting a
second one — TOML rejects a table defined twice. The sidebar *order* needs no
config: the plugin sets herdr's agent view to sort by rank. (`ui.agent_panel_sort
= "priority"` is only a fallback if that view is ever cleared.)

## Keys

| Key | Does |
| --- | --- |
| `alt+p` | Raise the focused agent's rank one step (stops at 5). |
| `alt+shift+p` | Lower it one step (stops at 1). |
| `alt+z` | Snooze it: 5m, 30m, 2h, 4h, off — one step per press. |
| `alt+g` | Go to the top of the ranking, cycling within the top band. |
| `prefix+p` | Open the ranked picker. |

`alt+shift+p` needs the kitty keyboard protocol between your terminal and
herdr: in the legacy encoding it is `ESC P`, which starts a DCS string, and
herdr waits for a terminator that never comes. foot, kitty, ghostty and
wezterm negotiate it.

Inside the picker: type to filter (the query survives every action), `enter`
jumps, `alt+p`/`alt+shift+p` nudge, `alt+z` snoozes, `alt+1`–`alt+5` rank
outright (`alt+3` = unranked), `ctrl+backspace` deletes a word, `esc` closes.

## The scale

Five is most important, one least, and **three means unranked**: landing back
on three removes the label rather than writing `P3`, because unset already
sorts as three and thirty meaningless labels are noise.

## alt+g

It goes to the **top band** — every waiting agent sharing the highest rank —
and cycles within it. It never drops you onto a 4 because you pressed again:
pressing past what you called most important is how a ranking rots into a
to-do list. Waiting means blocked, done or idle; working and snoozed agents
are skipped. When the band is just the agent you are on, it says so and names
your demote and picker keys.

## Snooze

For "waiting on someone else". A snoozed agent leaves the alt+g queue until
its time is up, then simply counts again. The sidebar shows the time left,
`zz 24m`, refreshed once a minute by one small background process that exits
when nothing is snoozed; the picker shows the wake time.

## Requirements

`jq`, `fzf` (recent: the picker uses `--track`, `--id-nth` and
`--with-shell`), `python3` ≥ 3.11, util-linux `flock` and `setsid`.
`notify-send` is optional (rank and snooze toasts).

## State

Everything lives in herdr's state directory for this plugin,
`${XDG_STATE_HOME:-~/.local/state}/herdr/plugins/agent-priority/`:

| File | Holds |
| --- | --- |
| `agent-priority` | The ranks — the source of truth. |
| `agent-snooze` | Active snoozes: pane, wake time, step. |
| `agent-priority.lock` | Serialises every store write and label write. |
| `agent-snooze.ticker.lock` | Held by the one label ticker. |
| `agent-priority.log` | A line per invocation. |
| `agent-priority.selection`, `agent-priority.notify-id` | Picker hand-off, toast id. |

Running the script by hand from a plain shell, point it at that directory, or
it uses a separate fallback (`…/state/herdr-agent-priority/`):

```sh
HERDR_PLUGIN_STATE_DIR=~/.local/state/herdr/plugins/agent-priority \
  "$(herdr plugin list | sed -n 's/.*agent-priority.*\[[a-z]*:\(.*\)\]/\1/p')/agent-priority.sh" list
```

## When a key looks dead

Read `agent-priority.log` in the state directory first, then
`herdr plugin log list --plugin agent-priority`. Keybind commands run with no
terminal attached, so a failure is otherwise silent.

## Development

```sh
herdr plugin link /path/to/checkout
sh tests/test.sh
```

The offline suite drives the real script against stub `herdr`, `setsid`,
`fzf`, `sleep` and `notify-send` on `PATH`, in a temp `HOME`/`XDG_STATE_HOME`
with a socket path that does not exist, so it never touches a live session.

## License

MIT — see [LICENSE](LICENSE).
````

The `herdr plugin list | sed` one-liner was checked against a real local link on 2026-09-27 (it printed `/home/daniel/dotfiles/terminal/.config/herdr/plugins/agent-priority`); Task 14 Step 2 checks it against a GitHub install, whose source tag differs.

- [ ] **Step 6: CI** — `.github/workflows/test.yml`:

```yaml
name: test
on:
  push:
  pull_request:
# Read-only: the job checks out and runs tests, nothing else.
permissions:
  contents: read

jobs:
  offline:
    runs-on: ubuntu-latest
    steps:
      # Pinned to a full commit SHA (same pin as Mindful-Stack/omascape): a tag can be moved.
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
      - name: Install jq
        run: sudo apt-get update && sudo apt-get install -y jq
      # sh is dash on this runner, bash on the author's machine: both must pass.
      - name: Syntax
        run: sh -n agent-priority.sh && sh -n tests/test.sh
      - name: Offline suite
        run: sh tests/test.sh
```

- [ ] **Step 7: Run the suite** — `102` (fallback `83`), `no-fails`.

- [ ] **Step 8: Validate the manifest in isolation (never the live registry)**

```bash
R=$(mktemp -d)
env -u HERDR_CONFIG_PATH -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
  XDG_CONFIG_HOME="$R/config" XDG_STATE_HOME="$R/state" HERDR_SOCKET_PATH="$R/none.sock" \
  sh -c 'herdr plugin link ~/Source/herdr-agent-priority && herdr plugin list'
rm -rf "$R"
```
Expected: a `plugin_linked` JSON line listing the five actions, then `agent-priority (Agent priority) enabled [local:/home/daniel/Source/herdr-agent-priority]`. A manifest error is reported by `link`. (`plugin link` works with no server running — 0.8.2 docs, §"Install and link"; the fake socket keeps it from reaching the live one. `link` does try that socket, so `$R` must be short: a long path fails with "local socket name length exceeds capacity of sun_path" — `mktemp -d` under `/tmp` is fine. Checked on 2026-09-27 against a scratch copy of the Task 11 manifest; the live `plugins.json` hash was unchanged.)

- [ ] **Step 9: Commit** — `git add herdr-plugin.toml README.md LICENSE .github/workflows/test.yml tests/test.sh`; message `Plugin actions for every key; README, MIT license, CI` + trailers.

---

### Task 12: Publish — STOP for explicit user confirmation first

Creating a **public** GitHub repository under the Mindful-Stack org is outward-facing and not reversible in practice (it can be cloned the moment it exists).

- [ ] **Step 1: STOP.** Show the user `git -C ~/Source/herdr-agent-priority log --oneline`, the file list (`git ls-files`), and ask: "Create **public** repo `Mindful-Stack/herdr-agent-priority` and push `main`? (yes/no)". Do not continue without an explicit yes.

- [ ] **Step 2: Create and push**

```bash
cd ~/Source/herdr-agent-priority
gh repo create Mindful-Stack/herdr-agent-priority --public --source . --remote origin --push \
  --description "herdr plugin: rank waiting agents 1-5, jump to the top, snooze, ranked picker"
```

- [ ] **Step 3: Watch CI**

```bash
gh run list -R Mindful-Stack/herdr-agent-priority --limit 1
gh run watch -R Mindful-Stack/herdr-agent-priority --exit-status "$(gh run list -R Mindful-Stack/herdr-agent-priority --limit 1 --json databaseId -q '.[0].databaseId')"
```
Expected: success. If it fails, read `gh run view --log-failed`; the likely class is a bash-ism the dash runner rejects (fix, commit, push, re-watch — a push to an existing repo needs no new confirmation).

---

### Task 13: Author migration (live, human in the loop)

Order matters: between steps 3 and 7 no agent key may be pressed (tell the user before step 2).

- [ ] **Step 1: Baseline** — `mkdir -p ~/.cache/ap-migration && sh ~/.config/herdr/herdr-agent-priority.sh list > ~/.cache/ap-migration/before.txt; cat ~/.local/state/herdr/agent-priority ~/.local/state/herdr/agent-snooze` (read-only apart from one log line).
- [ ] **Step 2: Tell the user** not to press alt+p/alt+shift+p/alt+z/alt+g/prefix+p until told.
- [ ] **Step 3: Stop the old ticker, unlink the old plugin** (ticker branch: `pgrep -af 'herdr-agent-priority.sh ticker' && pkill -f 'herdr-agent-priority.sh ticker'`), then `herdr plugin unlink agent-priority`.
- [ ] **Step 4: Move the state**

```bash
old=~/.local/state/herdr
new=~/.local/state/herdr/plugins/agent-priority
ls -A "$new"          # expect nothing (empty on 2026-09-27)
for f in agent-priority agent-snooze agent-priority.log agent-priority.notify-id agent-priority.selection; do
  [ -e "$old/$f" ] && mv "$old/$f" "$new/$f"
done
rm -f "$old/agent-priority.lock" "$old/agent-snooze.ticker.lock"
ls -l "$new"
```

- [ ] **Step 5: Link the repo** — `herdr plugin link ~/Source/herdr-agent-priority && herdr plugin list && herdr plugin action list --plugin agent-priority`. Expected: `[local:/home/daniel/Source/herdr-agent-priority]` and five actions.
- [ ] **Step 6: Switch the five keybinds** in `~/dotfiles/terminal/.config/herdr/config.toml`: each `type = "shell"` / `command = 'sh -c "$HOME/.config/herdr/herdr-agent-priority.sh <sub>"'` becomes `type = "plugin_action"` / `command = "agent-priority.<sub>"` (open, up, down, goto, snooze). In the comments, "$pri is stamped by herdr-agent-priority.sh" → "by the agent-priority plugin (~/Source/herdr-agent-priority)", and the long priority comment block gains one line: "The keys are the plugin's actions; see its README." Then `herdr config check && herdr server reload-config`.
- [ ] **Step 7: Restamp and compare** — `HERDR_PLUGIN_ROOT=~/Source/herdr-agent-priority HERDR_PLUGIN_STATE_DIR=~/.local/state/herdr/plugins/agent-priority sh ~/Source/herdr-agent-priority/agent-priority.sh stamp`, then the same env with `list > ~/.cache/ap-migration/after.txt; diff ~/.cache/ap-migration/before.txt ~/.cache/ap-migration/after.txt` (then `rm -rf ~/.cache/ap-migration`) → no diff (apart from agents whose status changed meanwhile — explain any line). Tell the user keys are live again.
- [ ] **Step 8: Remove the moved files from dotfiles and restow**

```bash
cd ~/dotfiles
git rm -q terminal/.config/herdr/herdr-agent-priority.sh
git rm -rq terminal/.config/herdr/plugins/agent-priority tests/herdr-agent-priority
stow -n -v -t ~ -R terminal     # dry run: expect only the UNLINK of herdr-agent-priority.sh
stow -t ~ -R terminal
test -e ~/.config/herdr/herdr-agent-priority.sh || echo gone
```

- [ ] **Step 9: README pointer** — replace `terminal/.config/herdr/README.md` with: a title `# herdr notes`; one paragraph: "Agent priority (ranks, alt+g, the picker, snooze) moved to its own plugin, [Mindful-Stack/herdr-agent-priority](https://github.com/Mindful-Stack/herdr-agent-priority), checked out and linked from `~/Source/herdr-agent-priority` (`herdr plugin link`). Its state is in `~/.local/state/herdr/plugins/agent-priority/`; its keys are the five `plugin_action` bindings in `config.toml`."; then keep the existing "## herdr behaviour worth knowing" section verbatim (it is about herdr, not the feature).
- [ ] **Step 10: Commit dotfiles**

```bash
cd ~/dotfiles
git add terminal/.config/herdr/config.toml terminal/.config/herdr/README.md
git status --short -- terminal tests     # only the removals, config.toml, README.md
git commit -m "herdr: agent priority now lives in Mindful-Stack/herdr-agent-priority

Keybinds switch to the plugin's actions; script, manifest and tests leave
dotfiles; README points at the repo.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013eVjtaWhwxCpkrmZkWssH1"
```

- [ ] **Step 11: HUMAN live verify** — the user presses each key; agent reads `tail ~/.local/state/herdr/plugins/agent-priority/agent-priority.log` and `herdr plugin log list --plugin agent-priority --limit 10 | jq -r '.result.logs[] | "\(.action_id // .event) \(.status)"'` after each:
  `alt+p` → toast "Priority N", `run up` logged, action `succeeded`; `alt+shift+p` → down; `alt+z` → `zz 5m` label + one ticker whose command line is under `~/Source/herdr-agent-priority`; `alt+g` → moves; `prefix+p` → popup opens, `alt+5` on a row re-ranks it in place (proves the quoted `$SELF` binds), `enter` jumps; the `alt+g` "top of the ranking" toast still names `alt+shift+p` and `alt+space p` (proves `keybind_for` reads `plugin_action`). Deferred to the next natural restart: labels return (startup `stamp`).

---

### Task 14: Clean-install smoke test in an isolated herdr

Isolation per the spec and past lessons: its own `XDG_CONFIG_HOME` (registry, config, socket dir), `XDG_STATE_HOME` (plugin state), and an explicit `HERDR_SOCKET_PATH` — **never `HERDR_CONFIG_PATH`**. Every step sources the same env file, because each shell call is fresh.

- [ ] **Step 1: Environment and live baseline**

```bash
R=$(mktemp -d /tmp/hap-smoke.XXXXXX)      # short: socket paths max 108 bytes
cat >"$R/env.sh" <<EOF
unset HERDR_CONFIG_PATH HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_BIN_PATH HERDR_CLIENT_SOCKET_PATH
export XDG_CONFIG_HOME=$R/config XDG_STATE_HOME=$R/state XDG_DATA_HOME=$R/data XDG_CACHE_HOME=$R/cache
export HERDR_SOCKET_PATH=$R/herdr.sock
EOF
echo "$R"
# Not agent-snooze: the live stamp hook rewrites it whenever a snooze expires.
sha256sum ~/.config/herdr/plugins.json ~/.local/state/herdr/plugins/agent-priority/agent-priority >"$R/live.before"
```
Ask the user not to use the agent keys until Step 7.

- [ ] **Step 2: Config from the README, install**

```bash
. "$R/env.sh"; mkdir -p "$XDG_CONFIG_HOME/herdr"
{ printf 'onboarding = false\n\n[keys]\nprefix = "alt+space"\n\n'
  curl -fsSL https://raw.githubusercontent.com/Mindful-Stack/herdr-agent-priority/main/README.md |
    awk '/<!-- keys-snippet -->/ { on = 1; next } on && /^```toml/ { p = 1; next } p && /^```/ { exit } p'
  printf '\n[ui.sidebar.agents]\nrows = [["state_icon", "$pri", { token = "$snz", dim = true }, "workspace", "tab"], ["agent"]]\n'
} >"$XDG_CONFIG_HOME/herdr/config.toml"
herdr config check
herdr plugin install Mindful-Stack/herdr-agent-priority --yes
herdr plugin list
herdr plugin list | sed -n 's/.*agent-priority.*\[[a-z]*:\(.*\)\]/\1/p'
```
Expected: `config: ok`; the plugin listed with a managed path under `$R`; the README's one-liner prints exactly that path (if it prints nothing, fix the README's pattern for the GitHub source tag and push).

- [ ] **Step 3: Start an isolated server** — `. "$R/env.sh"; herdr server` with `run_in_background`; then poll up to 10 s: `for i in $(seq 50); do herdr workspace list >/dev/null 2>&1 && break; command -p sleep 0.2; done; herdr workspace list`.

- [ ] **Step 4: Make an agent** — `herdr workspace create --label smoke --no-focus`; `pane=$(herdr pane list | jq -r '.result.panes[0].pane_id')`; `herdr pane report-agent "$pane" --source smoke --agent claude --state blocked`; `herdr agent list | jq '.result.agents | length'` → `1`. If it stays `0`, STOP and ask the user to attach (`. $R/env.sh; herdr`) and start `claude` in that pane. Then `herdr agent focus "$pane"`.

- [ ] **Step 5: Exercise through actions**

```bash
. "$R/env.sh"; S=$XDG_STATE_HOME/herdr/plugins/agent-priority
herdr plugin action invoke agent-priority.up
herdr plugin action invoke agent-priority.snooze
herdr plugin action invoke agent-priority.goto
cat "$S/agent-priority" "$S/agent-snooze"; tail -n5 "$S/agent-priority.log"
herdr agent list | jq -r '.result.agents[0].tokens'
herdr plugin log list --plugin agent-priority | jq -r '.result.logs[] | "\(.action_id // .event) \(.status)"'
pgrep -af 'agent-priority.sh ticker' | grep -F "$R"
```
`action invoke` starts the command and returns (herdr runs it asynchronously, like any plugin command), so if a file is still empty, re-read it once the plugin log shows that action `succeeded`. `up` and `snooze` may run concurrently; the store lock serialises them.
Expected: `<pane>\t4`; one snooze line; tokens show `pri: P4`, `prisort: 4`, `snz: zz 5m` (the real server applying the TTL'd label); `run goto` in the isolated log; every action `succeeded`; one ticker whose path is under `$R`.

- [ ] **Step 6: Tear down** — `. "$R/env.sh"; herdr server stop; pkill -f "$R/.*agent-priority.sh ticker" || true`.

- [ ] **Step 7: Prove the live setup was untouched** — `sha256sum -c "$R/live.before"` → all `OK`; `grep -c "$R" ~/.local/state/herdr/plugins/agent-priority/agent-priority.log` → `0`. Then `rm -rf "$R"`, tell the user keys are free.

---

## Self-review

**1. Spec coverage.**
- Part 1 mechanism (source/token, TTL clamp, every write under the lock, `tick_pass` order 1–4, format, singleton + in-lock handoff, self-healing, start after lock with fd 9 closed): Tasks 3, 4, 5. Writes-outside-ticker table: Task 3 (rung, off), Task 5 (stamp). Logged-not-fatal: Tasks 3, 4 tests. Risk gate: Task 1; fallback: Task 3 variant + 4F. Display: Task 6. Testing items 1–8: 1, 2, 7 → Task 3; 3, 3b, 3c, 3d, 4 → Task 4; 5, 6, 8 → Tasks 3/5. Live: Task 6.
- Part 2 goal, layout, manifest table, script changes (SELF, shq, STATE_DIR, socket, key hints; popup unchanged), README sections, CI, author setup, testing (suite moves, SELF/STATE_DIR/keybind tests, CI green, clean-install smoke, live), risks (plugin_action proven live in Tasks 13/14; `min_herdr_version = "0.8.2"`): Tasks 7–14.

**2. Placeholders.** None of TBD/TODO/"similar to". The README's `herdr plugin list | sed` one-liner is verified for a local link and re-checked for a GitHub install in Task 14 Step 2.

**3. Consistency.** `snz_report <pane> <wake> <caller>`, `snz_clear <pane> <caller>`, `ensure_ticker`, `ticker_release`, `tick_probe`, `tick_pass`, `$SNZ_SOURCE`, `$TICKER_LOCK`, `AGENT_PRIORITY_TICK_ONCE`, `AGENT_PRIORITY_TICK_PROBE`, `HERDR_STUB_FAIL_SNOOZE_META`, harness `seed_snooze`/`set_snz`/`snz_lines`/`ticker_once`/`fd9_in` — same names in every task. Log strings asserted (`snooze: snz clear failed for`, `tick: snz report failed for`, `ticker: already running`) match the code (`log "$2: snz clear failed for $1"` with caller `snooze`; `log "$3: snz report failed for $1"` with caller `tick`).

**4. Would-it-fail.** Every test step states its red reason. Checks that pass vacuously before their code exists are named as such (fd 9 closed, concurrent tick, "switches off", the pane-list loop) and each has an explicit break-it step (Task 2 Step 6, Task 3 Step 6, Task 4 Step 6, Task 5 Step 5). No test asserts a value it supplied: the TTL and label values come from the script's own arithmetic on a wake the test seeded as an *offset*; the handoff probe reads lock state the script holds, not state the test set; the singleton test's held lock is the input and "no writes" is the output. The Task 2 fd-probe self-check exists precisely because "fd 9 not open" could otherwise never fail.

**5. Spec conflicts resolved.** The spec was amended in the same commit as this plan, in place, for each of: `setsid -f` without `&`; the stub reads `/proc/$$/fd`; gate triggers (plugin action + shell keybind; startup confirmed by the deferred restart check); the stay-or-exit decision is driven by the store, and a failed store read *stops* the ticker (was "skip this pass"); the tick-probe seam and stub `sleep`; `dim` confirmed; the plugin state dir (no `state-dir` verb; path from source + disk); `--with-shell='sh -c'`; absolute, CDPATH-safe `SELF`; action `contexts`; stub `fzf` and the README/config equality test.

**Dry run.** Every code block in Tasks 2–11 was applied to scratch copies (both branches for Part 1) and the suite run after each task: 53 → 64 → 81 → 88 (fallback 63 → 69) → 88 → 94 → 97 → 99 → 102, each "fails first" and "prove it can fail" step behaving as written. It found three defects, fixed above: the Task 8 "none-left" grep (`\b` matches before `-`), the two ticker-start expectations Task 8 must rewrite, and the unguarded `wake=$(awk …)` that aborted the runner during Task 8's red run. An independent reviewer agent reproduced the counts and flagged the Task 1 polling race (fixed) plus the `sleep 60 8>&-`, `CDPATH`, and Task 14 hash/pgrep points (adopted).
