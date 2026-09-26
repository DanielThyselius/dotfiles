# herdr Agent Snooze Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a pane be snoozed out of the alt+g queue for 5m/30m/2h/4h, make the picker keep search always on with every command on alt, and serialise all store writes under one lock.

**Architecture:** Everything lives in the one POSIX sh script `herdr-agent-priority.sh`. Snoozes are a second tab-separated state file read lazily by `queue()` and `rows()`; nothing runs on expiry. An offline test script drives the real script against a stub `herdr` on `PATH`, so no test touches the live session.

**Tech Stack:** POSIX sh, jq 1.8, awk, util-linux `flock`, fzf 0.74, notify-send, herdr CLI.

**Spec:** `docs/agent/specs/2026-09-24-herdr-agent-snooze-design.md`

**Branch:** dotfiles commits straight to `master` (its history is all direct commits). The working tree has unrelated uncommitted Hyprland/Omarchy changes — **only ever `git add` the exact paths named in a step**, never `-A` or `.`.

---

## File map

| Path (relative to `~/dotfiles`) | Responsibility |
| --- | --- |
| `terminal/.config/herdr/herdr-agent-priority.sh` | The feature. Modified in every code task. |
| `terminal/.config/herdr/config.toml` | alt+z keybind, comments. Task 8. |
| `terminal/.config/herdr/README.md` | User-facing docs. Task 8. |
| `tests/herdr-agent-priority/test.sh` | Create. Offline test runner. |
| `tests/herdr-agent-priority/agents.json` | Create. Fixture: the `herdr agent list` response. |
| `tests/herdr-agent-priority/bin/herdr` | Create. Stub CLI serving the fixture. |
| `tests/herdr-agent-priority/bin/notify-send` | Create. Stub that records toasts. |

`tests/` is a new top-level directory. Top-level directories in this repo are stow packages, but a package is only linked when named explicitly (`stow terminal`), so `tests/` is never stowed.

---

### Task 1: Offline test harness (+ regression test for the keybind-hint fix)

This is **shared test infrastructure** — every later task asserts through it. It is the highest-stakes task in the plan.

**What the fixture must genuinely reproduce:**
- `herdr agent list` JSON with the fields the script reads: `pane_id`, `focused`, `agent_status`, `terminal_title_stripped`, `state_change_seq`, `tokens.pri`, `tokens.prisort`, `workspace_id`, `tab_id` (shape taken from a live `herdr agent list` on 2026-09-26).
- `herdr pane list` derived from the same agents, so the two can never disagree about which panes exist.
- `pane report-metadata` must not reach a server; it is appended to a log so tests can see it.

**What the environment cannot supply:** the fixture's `tokens` are static. The real server updates `tokens.pri` after `report-metadata`; the stub does not. So tests asserting a rank change read the **store file**, never a later `agent list`. Queue/rows tests set the tokens they need in the fixture directly.

**Isolation that must not collapse:** `HOME` and `XDG_STATE_HOME` point into a temp dir. `set_view` connects to `$HOME/.config/herdr/herdr.sock`; with a fake `HOME` that socket does not exist and `set_view` fails silently (it ends in `|| true`), so `stamp` can never re-sort the live sidebar.

**Files:**
- Create: `tests/herdr-agent-priority/agents.json`
- Create: `tests/herdr-agent-priority/bin/herdr`
- Create: `tests/herdr-agent-priority/bin/notify-send`
- Create: `tests/herdr-agent-priority/test.sh`
- Commit alongside: the already-written, uncommitted keybind-hint fix in `terminal/.config/herdr/herdr-agent-priority.sh` and `terminal/.config/herdr/config.toml`

- [ ] **Step 1: Write the fixture**

`tests/herdr-agent-priority/agents.json`:

```json
{"result":{"agents":[
 {"pane_id":"w1:p1","focused":false,"agent_status":"done","terminal_title":"alpha","terminal_title_stripped":"alpha","state_change_seq":10,"tokens":{"pri":"P5","prisort":"5"},"workspace_id":"w1","tab_id":"w1:t1"},
 {"pane_id":"w1:p2","focused":true,"agent_status":"idle","terminal_title":"beta","terminal_title_stripped":"beta","state_change_seq":20,"tokens":{"prisort":"3"},"workspace_id":"w1","tab_id":"w1:t1"},
 {"pane_id":"w1:p3","focused":false,"agent_status":"working","terminal_title":"gamma","terminal_title_stripped":"gamma","state_change_seq":30,"tokens":{"pri":"P5","prisort":"5"},"workspace_id":"w1","tab_id":"w1:t1"},
 {"pane_id":"w1:p4","focused":false,"agent_status":"done","terminal_title":"delta","terminal_title_stripped":"delta","state_change_seq":40,"tokens":{"pri":"P5","prisort":"5"},"workspace_id":"w1","tab_id":"w1:t1"}
]}}
```

With this fixture the alt+g queue is `w1:p1, w1:p4, w1:p2` (P5 done by seq, then P3 idle; p3 is working and excluded).

- [ ] **Step 2: Write the stubs**

`tests/herdr-agent-priority/bin/herdr`:

```sh
#!/bin/sh
# Stub herdr CLI for the offline tests. Serves $FIXTURE_DIR/agents.json and
# records writes instead of sending them anywhere.
set -eu
F=$FIXTURE_DIR
case "$1 ${2:-}" in
"agent list") cat "$F/agents.json" ;;
"pane list")
  jq '{result: {panes: [.result.agents[] | {pane_id, workspace_id, tab_id}]}}' "$F/agents.json" ;;
"workspace list") echo '{"result":{"workspaces":[{"workspace_id":"w1","label":"ws"}]}}' ;;
"tab list") echo '{"result":{"tabs":[{"tab_id":"w1:t1","label":"tab"}]}}' ;;
"pane report-metadata") printf '%s\n' "$*" >>"$F/metadata.log" ;;
*) : ;;
esac
```

`tests/herdr-agent-priority/bin/notify-send`:

```sh
#!/bin/sh
# Stub notify-send: record the call, hand back an id like the real one.
printf '%s\n' "$*" >>"$FIXTURE_DIR/toasts.log"
echo 1
```

Run: `chmod +x ~/dotfiles/tests/herdr-agent-priority/bin/*`

- [ ] **Step 3: Write the runner with the goto-hint test**

`tests/herdr-agent-priority/test.sh`:

```sh
#!/bin/sh
# Offline tests for herdr-agent-priority.sh.
#
#   sh tests/herdr-agent-priority/test.sh
#
# A stub `herdr` on PATH serves agents.json; HOME and XDG_STATE_HOME point at a
# temp dir, so nothing reaches the live session — set_view's socket lives under
# $HOME and simply is not there. The stub's tokens never change after a write,
# so rank assertions read the store file, not a later `agent list`.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SCRIPT="$REPO/terminal/.config/herdr/herdr-agent-priority.sh"
CONFIG="$REPO/terminal/.config/herdr/config.toml"
PATH="$HERE/bin:$PATH"
export PATH

failed=0
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    printf 'FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$2" "$3"
    failed=1
  fi
}

setup() {
  T=$(mktemp -d)
  HOME="$T/home"
  XDG_STATE_HOME="$T/state"
  FIXTURE_DIR="$T/fx"
  HERDR_CONFIG_PATH="$CONFIG"
  export HOME XDG_STATE_HOME FIXTURE_DIR HERDR_CONFIG_PATH
  unset AGENT_PRIORITY_CRIT_DELAY 2>/dev/null || true
  mkdir -p "$HOME" "$FIXTURE_DIR"
  cp "$HERE/agents.json" "$FIXTURE_DIR/agents.json"
  : >"$FIXTURE_DIR/toasts.log"
  : >"$FIXTURE_DIR/metadata.log"
}

# Never abort the runner: a failing script (e.g. "unknown command" before a
# feature exists) must show up as failed checks, not kill the remaining tests.
run() { sh "$SCRIPT" "$@" || true; }
state() { printf '%s/herdr/%s' "$XDG_STATE_HOME" "$1"; }
fixture() { # fixture <jq filter>: rewrite the agent list in place
  jq "$1" "$FIXTURE_DIR/agents.json" >"$FIXTURE_DIR/a.tmp"
  mv "$FIXTURE_DIR/a.tmp" "$FIXTURE_DIR/agents.json"
}
queue_ids() { run list | awk '{ print $3 }' | tr '\n' ' ' | sed 's/ $//'; }

# --- goto: the "already at the top" hint names the configured keys ----------
setup
fixture '.result.agents |= map(select(.pane_id != "w1:p4")
                               | .focused = (.pane_id == "w1:p1"))'
run goto
check "goto hint names the configured demote and picker keys" \
  "yes" \
  "$(grep -qF 'alt+shift+p to lower it · alt+space p to pick another' \
      "$FIXTURE_DIR/toasts.log" && echo yes || echo no)"

setup
fixture '.result.agents |= map(select(.pane_id != "w1:p4")
                               | .focused = (.pane_id == "w1:p1"))'
printf '[keys]\nprefix = "alt+space"\n' >"$T/bare.toml"
HERDR_CONFIG_PATH="$T/bare.toml" run goto
check "goto hint is omitted when nothing is bound" \
  "no" \
  "$(grep -qF ' to lower it' "$FIXTURE_DIR/toasts.log" && echo yes || echo no)"

exit "$failed"
```

What these distinguish: the first fails if the hint is hardcoded to anything other than what `config.toml` binds today; the second fails if the hint is hardcoded at all (the keys are absent from `bare.toml`, so a correct `keybind_for` returns nothing).

- [ ] **Step 4: Run the tests**

Run: `sh ~/dotfiles/tests/herdr-agent-priority/test.sh`
Expected: both `ok`. The fix already exists (it was written before this plan).

- [ ] **Step 5: Prove the first test can fail for the stated reason**

Temporarily break the lookup: in `keybind_for`, change the regex prefix `herdr-agent-priority\.sh\s+` to `herdr-agent-priorityX\.sh\s+`. Rerun: the first check must FAIL (hint absent), the second stays ok. Revert and rerun: both ok. This proves the first check is reading the real config, not passing by accident.

- [ ] **Step 6: Commit (harness + the pending hint fix)**

```bash
cd ~/dotfiles
git add tests/herdr-agent-priority terminal/.config/herdr/herdr-agent-priority.sh terminal/.config/herdr/config.toml
git commit -m "herdr: priority toast reads keybinds from config; offline test harness

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013eVjtaWhwxCpkrmZkWssH1"
```

---

### Task 2: One lock around every store read-modify-write (rank path)

**Property:** N concurrent `up` calls on the same pane advance it N steps (clamped), and the pane metadata stamp is sent in the same order as the store writes.

**Spec deviation, resolved here and in the spec:** the spec put the metadata stamp outside the lock. That reintroduces a race — process A writes 4, B writes 5, B stamps 5, A stamps 4, sidebar shows P4 while the store says 5. `stamp_one` therefore runs **inside** the lock (one ~ms local socket call); only the title lookup and toast are outside. Task 2 Step 7 updates the spec to match.

**Files:**
- Modify: `terminal/.config/herdr/herdr-agent-priority.sh` — state block (~line 66-73), `store_set`/`stamp_one`/`apply` (~169-222), `up | down)`/`set)`/`clear)` cases (~354-385)
- Test: `tests/herdr-agent-priority/test.sh`

- [ ] **Step 1: Add the test seam only (no lock yet)**

After `STORE=...` block add `LOCK`, and after `die()` add:

```sh
# Test seam. Widens the gap between reading a store and writing it back, so the
# concurrency tests can tell a locked store from an unlocked one — without it
# the window is a few milliseconds and the race only shows up by luck. Unset in
# normal use, where it costs one test.
crit_delay() { [ -z "${AGENT_PRIORITY_CRIT_DELAY:-}" ] || sleep "$AGENT_PRIORITY_CRIT_DELAY"; }
```

and in `up | down)` insert `crit_delay` on the line after the `case $cur in ... esac` read, before computing `next`.

- [ ] **Step 2: Write the failing concurrency test**

Append before `exit "$failed"`:

```sh
# --- lock: concurrent nudges are not lost ------------------------------------
setup
AGENT_PRIORITY_CRIT_DELAY=0.3
export AGENT_PRIORITY_CRIT_DELAY
run up w1:p2 & run up w1:p2 & run up w1:p2 & wait
check "three concurrent ups from unranked land on 5" \
  "w1:p2	5" "$(cat "$(state agent-priority)")"
```

What it distinguishes: without a lock all three read unranked (3) inside the 0.3s window and all write 4, so the store says `4`. With the lock they serialise: 4, 5, 5.

- [ ] **Step 3: Run it to see it fail for that reason**

Run: `sh ~/dotfiles/tests/herdr-agent-priority/test.sh`
Expected: `FAIL three concurrent ups...` with actual `w1:p2	4`. Any other actual value (empty, error text) means the harness is broken — fix that first.

- [ ] **Step 4: Implement the lock**

State block, next to `NOTIFY_ID`:

```sh
LOCK="$STATE_DIR/agent-priority.lock"
```

After `crit_delay`:

```sh
# Every read-modify-write of a store runs under one exclusive lock. Each
# keypress is its own process, and repeated presses are the intended
# interaction, so without it two quick presses both read the old value and one
# step is lost. The brace group runs in THIS shell, so a critical section's
# results (next, step, wake) are visible to the caller afterwards; the lock is
# released when fd 9 closes at the end of the group, or when the process exits.
locked() { # locked <command...>
  { flock 9; "$@"; } 9>"$LOCK"
}
```

(flock(1): "flock [options] number … the lock is applied to the file descriptor"; closing the descriptor releases it — util-linux man page, `flock(1)`, DESCRIPTION.)

Replace `apply()` with the critical sections plus the announcing wrapper:

```sh
# Critical sections, run under `locked`. The metadata stamp is inside on
# purpose: stamped outside, two presses could write 4 then 5 but stamp 5 then 4,
# leaving the sidebar disagreeing with the store. Toasts stay outside.
rank_write() { # rank_write <pane_id> <priority|"">
  store_set "$1" "$2"
  stamp_one "$1" "$2"
}

rank_step() { # rank_step <pane_id> <up|down>; sets $next
  cur=$(stored "$1")
  case $cur in 1 | 2 | 3 | 4 | 5) ;; *) cur=$DEFAULT ;; esac
  crit_delay
  if [ "$2" = up ]; then
    next=$((cur + 1))
    [ "$next" -le 5 ] || next=5
  else
    next=$((cur - 1))
    [ "$next" -ge 1 ] || next=1
  fi
  [ "$next" != "$DEFAULT" ] || next=''
  rank_write "$1" "$next"
}

apply() { # apply <pane_id> <priority|"">
  locked rank_write "$1" "$2"
  notify "$1" "$2"
}
```

Replace the body of `up | down)` with:

```sh
up | down)
  pane=$(target_pane "${1:-}")
  [ -n "$pane" ] || exit 0
  locked rank_step "$pane" "$cmd"
  notify "$pane" "$next"
  ;;
```

(`set)` and `clear)` already go through `apply`, so they are covered.) Remove the Step 1 `crit_delay` line from the old `up | down)` body — it now lives in `rank_step`.

- [ ] **Step 5: Run tests**

Run: `sh ~/dotfiles/tests/herdr-agent-priority/test.sh`
Expected: all `ok`, including `three concurrent ups from unranked land on 5`.

- [ ] **Step 6: Syntax check**

Run: `sh -n ~/dotfiles/terminal/.config/herdr/herdr-agent-priority.sh && echo ok`
Expected: `ok`

- [ ] **Step 7: Align the spec**

In `docs/agent/specs/2026-09-24-herdr-agent-snooze-design.md`, section **Locking**, replace the sentence beginning "The herdr metadata stamp, the toast and any other API calls happen outside it" with:

```
The rank path's metadata stamp (`report-metadata`) runs inside it, so the
sidebar token is written in the same order as the store; stamped outside, two
presses could write 4 then 5 but stamp 5 then 4. The title lookup and the
toast happen outside, so a slow notification never holds up the next press.
```

- [ ] **Step 8: Commit**

```bash
cd ~/dotfiles
git add terminal/.config/herdr/herdr-agent-priority.sh tests/herdr-agent-priority/test.sh docs/agent/specs/2026-09-24-herdr-agent-snooze-design.md
git commit -m "herdr: serialise priority store writes under one flock

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013eVjtaWhwxCpkrmZkWssH1"
```

---

### Task 3: Validate explicit pane ids

**Property:** an explicit pane id that is not a live agent writes nothing to any store and exits 0.

**Files:**
- Modify: `terminal/.config/herdr/herdr-agent-priority.sh` — `target_pane()` (~line 161)
- Test: `tests/herdr-agent-priority/test.sh`

- [ ] **Step 1: Write the failing test**

```sh
# --- explicit pane ids are validated -----------------------------------------
setup
run up w9:nope
check "up on an unknown pane writes nothing" "" "$(cat "$(state agent-priority)")"
```

Distinguishes: today `target_pane` echoes the argument unchecked, so the store gains `w9:nope	4`.

- [ ] **Step 2: Run to see it fail**

Run: `sh ~/dotfiles/tests/herdr-agent-priority/test.sh`
Expected: `FAIL up on an unknown pane writes nothing` with actual `w9:nope	4`.

- [ ] **Step 3: Implement**

Replace `target_pane()`:

```sh
# Resolve the pane a command applies to: explicit argument, else the focused
# one. An explicit id is checked against the live agent list and resolves to
# nothing if it is not there, so a stale or mistyped id can never put a line in
# a store. Read from the agent list rather than $HERDR_PANE_ID so the same
# script works from a keybind, a plugin action and a shell inside some other
# pane.
target_pane() {
  if [ -n "${1:-}" ]; then
    herdr agent list | jq -r --arg p "$1" \
      'first(.result.agents[] | select(.pane_id == $p) | .pane_id) // empty'
  else
    focused_pane
  fi
}
```

- [ ] **Step 4: Run tests** — Expected: all `ok`.

- [ ] **Step 5: Align the spec**

In the spec's **Error handling**, replace "The validation reuses the list call already needed for the toast title, so it costs nothing extra." with "This costs one extra `herdr agent list` call (a few milliseconds) per invocation with an explicit id."

- [ ] **Step 6: Commit**

```bash
cd ~/dotfiles
git add terminal/.config/herdr/herdr-agent-priority.sh tests/herdr-agent-priority/test.sh docs/agent/specs/2026-09-24-herdr-agent-snooze-design.md
git commit -m "herdr: validate explicit pane ids before writing priority state

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013eVjtaWhwxCpkrmZkWssH1"
```

---

### Task 4: The snooze store and `snooze` command

**Property:** each call steps the pane along 5 → 30 → 120 → 240 → off, measured from now; malformed or expired lines behave as unsnoozed and vanish on the next write; concurrent calls each advance one rung; different panes never overwrite each other.

**Files:**
- Modify: `terminal/.config/herdr/herdr-agent-priority.sh` — header usage, state block, new helpers after `stamp_one`, new `snooze)` case before `goto)`
- Test: `tests/herdr-agent-priority/test.sh`

- [ ] **Step 1: Write the failing tests**

```sh
# --- snooze ladder -------------------------------------------------------------
snooze_step_of() { awk -F'\t' -v p="$1" '$1 == p { print $3 }' "$(state agent-snooze)"; }

setup
steps=''
for _ in 1 2 3 4 5; do
  run snooze w1:p1
  steps="$steps $(snooze_step_of w1:p1)"
done
check "snooze ladder 5,30,120,240,off" " 5 30 120 240 " "$steps"
check "snooze toast names duration" "yes" \
  "$(grep -qF 'Snoozed 5m' "$FIXTURE_DIR/toasts.log" && echo yes || echo no)"

setup
before=$(date +%s)
run snooze w1:p1
wake=$(awk -F'\t' '$1 == "w1:p1" { print $2 }' "$(state agent-snooze)")
check "5m wake is 300s from now" "yes" \
  "$([ "$wake" -ge $((before + 300)) ] && [ "$wake" -le $((before + 302)) ] && echo yes || echo no)"

setup
mkdir -p "$XDG_STATE_HOME/herdr"
printf 'w1:p1\t%s\t15\n' $(( $(date +%s) + 600 )) >"$(state agent-snooze)"
run snooze w1:p1
check "a step outside the ladder is treated as unsnoozed" "5" "$(snooze_step_of w1:p1)"

setup
mkdir -p "$XDG_STATE_HOME/herdr"
printf 'w1:p1\t%s\t30\n' $(( $(date +%s) - 1 )) >"$(state agent-snooze)"
run snooze w1:p1
check "an expired snooze restarts at 5m" "5" "$(snooze_step_of w1:p1)"

setup
run snooze w9:nope
check "snooze on an unknown pane writes nothing" "" "$(cat "$(state agent-snooze)" 2>/dev/null)"

setup
AGENT_PRIORITY_CRIT_DELAY=0.3
export AGENT_PRIORITY_CRIT_DELAY
run snooze w1:p1 & run snooze w1:p1 & run snooze w1:p1 & wait
check "three concurrent snoozes land on 120" "120" "$(snooze_step_of w1:p1)"
run snooze w1:p2 & run snooze w1:p4 & wait
check "concurrent snoozes of different panes both survive" "3" \
  "$(grep -c '' "$(state agent-snooze)")"
```

What they distinguish: ladder order and the off rung; duration arithmetic (a wrong unit, e.g. seconds instead of minutes, lands outside the window); step validation; expiry; pane validation; the lock (unlocked, three racers all read unsnoozed and write 5; two panes race and one line is lost, leaving 2 lines instead of 3 — p1, p2, p4).

- [ ] **Step 2: Run to see them fail**

Run: `sh ~/dotfiles/tests/herdr-agent-priority/test.sh`
Expected: the snooze checks FAIL because the script dies with `unknown command: snooze` (exit 2) — every snooze assertion reads an empty or missing file. Earlier tests still `ok`.

- [ ] **Step 3: Implement**

Header usage block, after the `clear` line:

```sh
#   herdr-agent-priority.sh snooze [pane_id]   step the snooze: 5m, 30m, 2h, 4h, off
```

State block, after `STORE=`:

```sh
SNOOZE="$STATE_DIR/agent-snooze"
```

and after `[ -f "$STORE" ] || : >"$STORE"`:

```sh
[ -f "$SNOOZE" ] || : >"$SNOOZE"
```

Helpers, after `stamp_one()`:

```sh
# SNOOZE. "Not right now" for a pane whose next step is waiting on someone
# else — another agent's review, a human, an email. A snoozed pane drops out of
# the alt+g queue until its time is up and then simply counts again: nothing
# runs at expiry, the queue just stops excluding it. Kept apart from the rank
# store because importance and timing are different facts.
#
# Lines are pane<TAB>wake_epoch<TAB>step, step in minutes. The step is stored
# rather than derived from the time left, because a half-used 30m would
# otherwise look like a fresh 15m and the next press would pick the wrong rung.

# Active snoozes only. A line with a non-numeric wake, a step off the ladder, or
# a wake in the past is not a snooze, and every rewrite drops it.
snoozes_active() {
  awk -F'\t' -v now="$(date +%s)" \
    '$2 ~ /^[0-9]+$/ && $3 ~ /^(5|30|120|240)$/ && $2 + 0 > now + 0' "$SNOOZE"
}

snooze_label() { # snooze_label <minutes>: 5m, 30m, 2h, 4h
  if [ "$1" -ge 60 ]; then echo "$(($1 / 60))h"; else echo "${1}m"; fi
}

snooze_step() { # snooze_step <pane_id>; run under `locked`; sets $step and $wake
  cur=$(snoozes_active | awk -F'\t' -v p="$1" '$1 == p { print $3; exit }')
  case $cur in
  '') step=5 ;;
  5) step=30 ;;
  30) step=120 ;;
  120) step=240 ;;
  *) step='' ;;
  esac
  crit_delay
  wake=''
  tmp=$(mktemp "$SNOOZE.XXXXXX")
  snoozes_active | awk -F'\t' -v p="$1" '$1 != p' >"$tmp"
  if [ -n "$step" ]; then
    wake=$(($(date +%s) + step * 60))
    printf '%s\t%s\t%s\n' "$1" "$wake" "$step" >>"$tmp"
  fi
  mv "$tmp" "$SNOOZE"
}
```

New case, before `goto)`:

```sh
snooze)
  # Each press moves one rung from wherever the pane is now; past 4h it is off.
  # Focus stays put so the key can be pressed again, and alt+g already skips
  # the pane, so the next alt+g goes somewhere else by itself.
  pane=$(target_pane "${1:-}")
  [ -n "$pane" ] || exit 0
  locked snooze_step "$pane"
  title=$(pane_title "$pane")
  [ -n "$title" ] || title="$pane"
  if [ -n "$step" ]; then
    toast "Snoozed $(snooze_label "$step")" "$title · until $(date -d "@$wake" +%H:%M)"
  else
    toast "Snooze off" "$title"
  fi
  ;;
```

Update the `die` usage string to include `snooze`:
`die "usage: $0 {up|down|set <1-5>|clear|snooze|goto|pick|rows|stamp|list} [pane_id]"`

- [ ] **Step 4: Run tests** — Expected: all `ok`.

- [ ] **Step 5: Commit**

```bash
cd ~/dotfiles
git add terminal/.config/herdr/herdr-agent-priority.sh tests/herdr-agent-priority/test.sh
git commit -m "herdr: snooze command (5m/30m/2h/4h/off) with its own store

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013eVjtaWhwxCpkrmZkWssH1"
```

---

### Task 5: alt+g skips snoozed panes

**Property:** `queue()` (hence `goto` and `list`) omits panes with an active snooze and includes them again once the wake time passes, with no other action.

**Files:**
- Modify: `terminal/.config/herdr/herdr-agent-priority.sh` — `queue()` (~line 268)
- Test: `tests/herdr-agent-priority/test.sh`

- [ ] **Step 1: Write the failing tests**

```sh
# --- queue skips snoozed panes -------------------------------------------------
setup
check "baseline queue" "w1:p1 w1:p4 w1:p2" "$(queue_ids)"
run snooze w1:p1
check "a snoozed pane leaves the queue" "w1:p4 w1:p2" "$(queue_ids)"

setup
mkdir -p "$XDG_STATE_HOME/herdr"
printf 'w1:p1\t%s\t5\n' $(( $(date +%s) - 1 )) >"$(state agent-snooze)"
check "an expired snooze is back in the queue" "w1:p1 w1:p4 w1:p2" "$(queue_ids)"

setup
fixture '.result.agents |= map(.focused = (.pane_id == "w1:p1"))'
run snooze w1:p1
run goto
check "goto from a snoozed pane moves to the next in band" "yes" \
  "$(grep -q 'goto focusing w1:p4' "$(state agent-priority.log)" && echo yes || echo no)"
```

Distinguishes: without the filter the second check still shows p1 first; the third guards against filtering on "has a line" rather than "is active"; the fourth checks alt+g end to end (the log line is written just before focusing).

- [ ] **Step 2: Run to see it fail** — Expected: `FAIL a snoozed pane leaves the queue` (actual `w1:p1 w1:p4 w1:p2`) and the goto check FAILs; baseline and expired checks `ok`.

- [ ] **Step 3: Implement**

In `queue()`, before `herdr agent list`, add:

```sh
  # Snoozed panes are not in the queue at all, so alt+g cannot land on them.
  # IN rather than `inside`: on arrays of strings `inside` matches substrings,
  # so "w1:p1" would count as inside ["w1:p10"].
  snoozed=$(snoozes_active | cut -f1 | jq -R -s -c 'split("\n") | map(select(length > 0))')
```

Change the jq invocation's arguments to `jq -r --argjson def "$DEFAULT" --argjson snoozed "$snoozed" '` and add, directly after the `select(.agent_status == ...)` line:

```jq
      | select(.pane_id | IN($snoozed[]) | not)
```

Also delete the stale trailing comment in `queue()`'s header that says "Only blocked and done are candidates. Working agents want nothing and idle ones have already been dealt with." — it contradicts the paragraph above it (idle is in the queue).

- [ ] **Step 4: Run tests** — Expected: all `ok`.

- [ ] **Step 5: Commit**

```bash
cd ~/dotfiles
git add terminal/.config/herdr/herdr-agent-priority.sh tests/herdr-agent-priority/test.sh
git commit -m "herdr: alt+g skips snoozed panes

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013eVjtaWhwxCpkrmZkWssH1"
```

---

### Task 6: `stamp` prunes both stores under the lock

**Property:** after `stamp`, the rank store has no lines for gone panes (existing behaviour, now locked) and the snooze store has no lines for gone panes, expired snoozes or malformed lines; active snoozes of live panes survive.

**Files:**
- Modify: `terminal/.config/herdr/herdr-agent-priority.sh` — `stamp)` case (~line 484)
- Test: `tests/herdr-agent-priority/test.sh`

- [ ] **Step 1: Write the failing test**

```sh
# --- stamp prunes the snooze store -------------------------------------------
setup
mkdir -p "$XDG_STATE_HOME/herdr"
future=$(( $(date +%s) + 600 ))
{
  printf 'w1:p1\t%s\t5\n' "$future"               # live, active: keep
  printf 'w9:gone\t%s\t5\n' "$future"             # pane gone: drop
  printf 'w1:p4\t%s\t5\n' $(( $(date +%s) - 1 ))  # expired: drop
  printf 'w1:p2\t%s\t15\n' "$future"              # bad step: drop
} >"$(state agent-snooze)"
run stamp
check "stamp keeps only live active snoozes" "w1:p1" "$(cut -f1 "$(state agent-snooze)")"
```

Distinguishes: without pruning all four lines remain. Each dropped line fails a different rule, so keeping any one of them exposes which rule is missing.

- [ ] **Step 2: Run to see it fail** — Expected: FAIL with actual listing all four ids.

- [ ] **Step 3: Implement**

Turn the store-rewrite half of `stamp)` into a critical section. Add after `snooze_step()`:

```sh
# Startup cleanup, run under `locked`: re-project the rank store onto metadata
# tokens (a restore wiped them), drop entries whose pane is gone from both
# stores, and drop expired or malformed snoozes, so neither file can grow
# without bound.
prune() {
  live=$(herdr pane list | jq -r '.result.panes[].pane_id' | sort -u)
  tmp=$(mktemp "$STORE.XXXXXX")
  while IFS='	' read -r pane pri; do
    [ -n "$pane" ] || continue
    if printf '%s\n' "$live" | grep -qx "$pane"; then
      printf '%s\t%s\n' "$pane" "$pri" >>"$tmp"
      stamp_one "$pane" "$pri"
    fi
  done <"$STORE"
  mv "$tmp" "$STORE"

  tmp=$(mktemp "$SNOOZE.XXXXXX")
  snoozes_active | while IFS='	' read -r pane wake step; do
    if printf '%s\n' "$live" | grep -qx "$pane"; then
      printf '%s\t%s\t%s\n' "$pane" "$wake" "$step"
    fi
  done >"$tmp"
  mv "$tmp" "$SNOOZE"
}
```

(`if … fi` rather than `grep && printf`: under `set -e` a false `&&` as the loop's last command makes the pipeline fail and kills the script.)

In `stamp)`, replace everything from `live=$(herdr pane list ...` through the first `mv "$tmp" "$STORE"` with `locked prune`. Leave the prisort loop and `set_view` after it unchanged.

- [ ] **Step 4: Run tests** — Expected: all `ok`.

- [ ] **Step 5: Commit**

```bash
cd ~/dotfiles
git add terminal/.config/herdr/herdr-agent-priority.sh tests/herdr-agent-priority/test.sh
git commit -m "herdr: stamp prunes snoozes and rewrites both stores under the lock

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013eVjtaWhwxCpkrmZkWssH1"
```

---

### Task 7: Picker rows show snoozes

**Property:** a snoozed row shows `zz HH:MM` (local wake time) in the status column, dimmed, and sorts after every unsnoozed row of the same rank.

**Files:**
- Modify: `terminal/.config/herdr/herdr-agent-priority.sh` — `rows()` (~line 296)
- Test: `tests/herdr-agent-priority/test.sh`

- [ ] **Step 1: Write the failing tests**

```sh
# --- picker rows show snoozes ------------------------------------------------
setup
run snooze w1:p1
rows_plain=$(run rows | sed 's/\x1b\[[0-9;]*m//g')
check "snoozed row sorts last in its band" "w1:p4 w1:p3 w1:p1 w1:p2" \
  "$(printf '%s\n' "$rows_plain" | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
wake=$(awk -F'\t' '$1 == "w1:p1" { print $2 }' "$(state agent-snooze)")
check "snoozed row shows its wake time" "yes" \
  "$(printf '%s\n' "$rows_plain" | grep '^w1:p1' | grep -qF "zz $(date -d "@$wake" +%H:%M)" && echo yes || echo no)"
```

Distinguishes: unmodified `rows()` puts p1 first (done, lowest seq) and shows `done`; the second catches a UTC-vs-local mistake (`strftime` instead of `strflocaltime`) whenever local time is not UTC — this machine is on CEST; under `TZ=UTC` that half would not distinguish anything.

- [ ] **Step 2: Run to see them fail** — Expected: both FAIL; order actual `w1:p1 w1:p4 w1:p3 w1:p2`.

- [ ] **Step 3: Implement**

In `rows()`, after the `tabs=$(...)` line:

```sh
  snoozed=$(snoozes_active | jq -R -s -c \
    '[split("\n")[] | select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber)}] | from_entries')
```

Add `--argjson snoozed "$snoozed"` to the `jq -r` call. In the object, add after `seq: .state_change_seq,`:

```jq
          wake: $snoozed[.pane_id],
```

Change the sort to put snoozed rows after the rest of their band:

```jq
    | sort_by(-.pri,
        (if .wake then 1 else 0 end),
        (if .status == "blocked" then 0
         elif .status == "done" then 1
         elif .status == "working" then 2
         else 3 end),
        .seq)
```

and the status field in the output array from `.status,` to:

```jq
        (if .wake then "zz \(.wake | strflocaltime("%H:%M"))" else .status end),
```

(`strflocaltime` on a number: verified on jq 1.8.2 here, `1790000000 | strflocaltime("%H:%M")` → `"16:13"`.)

In the awk formatter, widen the status column from `%-7s` to `%-8s` (`zz 14:30` is 8 characters). No colour change needed: anything that is not blocked/done/working already falls to the dim branch.

- [ ] **Step 4: Run tests** — Expected: all `ok`.

- [ ] **Step 5: Commit**

```bash
cd ~/dotfiles
git add terminal/.config/herdr/herdr-agent-priority.sh tests/herdr-agent-priority/test.sh
git commit -m "herdr: picker shows snoozed rows dimmed with their wake time

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013eVjtaWhwxCpkrmZkWssH1"
```

---

### Task 8: Picker keys, alt+z keybind, docs

No offline test: fzf needs a terminal and herdr's popup key routing cannot be stubbed. Verified live in Task 9.

**Files:**
- Modify: `terminal/.config/herdr/herdr-agent-priority.sh` — `pick)` case (~line 430)
- Modify: `terminal/.config/herdr/config.toml` — priority comment block (~line 243-290), new keybind after the `alt+g` entry (~line 312), zoom comment (~line 151-154)
- Modify: `terminal/.config/herdr/README.md` — key table, picker table, "What alt+g does", state-file table

- [ ] **Step 1: Replace the fzf invocation in `pick)`**

```sh
  # Typing always filters; every command is an alt chord, so no letter or digit
  # is ever taken from the query and the query survives each reload. That makes
  # chains like  herdr, alt+z, ctrl+backspace, smarticipate re, alt+shift+p
  # one continuous gesture.
  #
  # --track --id-nth 1 keeps the cursor on the same pane (field 1 is the hidden
  # pane id) when a reload re-sorts the list; without it a re-rank moves the row
  # out from under the cursor and the next alt+shift+p hits a different agent.
  # fzf's default for ctrl-bspace deletes one character, hence the rebind.
  sel=$(rows | fzf \
    --delimiter='\t' --with-nth=2.. --no-sort --cycle --ansi \
    --track --id-nth=1 \
    --prompt='agent > ' \
    --header='enter jump  ·  alt+p/alt+shift+p nudge  ·  alt+z snooze  ·  alt+1-5 rank (3 = unranked)  ·  esc close' \
    --bind='ctrl-bspace:backward-kill-word' \
    --bind="alt-1:execute-silent($SELF set 1 {1})+reload($SELF rows)" \
    --bind="alt-2:execute-silent($SELF set 2 {1})+reload($SELF rows)" \
    --bind="alt-3:execute-silent($SELF clear {1})+reload($SELF rows)" \
    --bind="alt-4:execute-silent($SELF set 4 {1})+reload($SELF rows)" \
    --bind="alt-5:execute-silent($SELF set 5 {1})+reload($SELF rows)" \
    --bind="alt-p:execute-silent($SELF up {1})+reload($SELF rows)" \
    --bind="alt-P:execute-silent($SELF down {1})+reload($SELF rows)" \
    --bind="alt-z:execute-silent($SELF snooze {1})+reload($SELF rows)" || true)
```

Update the comment above `pick)` from "1-5 re-rank the highlighted row" to "alt+1-5 re-rank the highlighted row".

(fzf key names from `fzf --man`: "alt-[*] (Any case-sensitive single character is allowed)", "ctrl-backspace (ctrl-bspace ctrl-bs)"; `--id-nth`: "fzf extracts the tracking key from the current item using the nth expression and searches for a matching item in the reloaded list".)

- [ ] **Step 2: Add the alt+z keybind** after the `alt+g` `[[keys.command]]` entry in `config.toml`:

```toml
[[keys.command]]
key = "alt+z"
type = "shell"
command = 'sh -c "$HOME/.config/herdr/herdr-agent-priority.sh snooze"'
description = "Snooze agent (5m/30m/2h/4h/off)"
```

- [ ] **Step 3: Update config.toml comments**

In the priority comment block, replace the paragraph starting "Inside the picker the same two keys nudge the HIGHLIGHTED row" with:

```
# Inside the picker the same keys act on the HIGHLIGHTED row: alt+p, alt+shift+p
# and alt+z mean one thing everywhere. alt+1-5 set a rank outright, but only in
# the picker — outside it they are switch_tab. Typing always filters, and the
# query survives each action, so several rows can be re-ranked in one go.
```

and after the alt+g paragraph add:

```
# alt+z snoozes the focused session: 5m, 30m, 2h, 4h, off, one rung per press.
# A snoozed session leaves the alt+g queue until its time is up and then counts
# again — nothing fires at expiry. It is for "waiting on someone else", which is
# a statement about timing; alt+shift+p is for a rank that has gone stale.
```

In the zoom comment, replace "alt+z carries the same mnemonic with no readline collision if that trade turns out to bite." with "alt+z would have been the fallback, but it is now agent snooze."

- [ ] **Step 4: Update README.md**

Key table — add after the `alt+shift+p` row:

```
| `alt+z` | Snooze the focused session: 5m, 30m, 2h, 4h, off, one step per press. |
```

Picker table — replace the whole table with:

```
| Key | Does |
| --- | --- |
| type | Filter. The query stays put after every action below. |
| `enter` | Jump to the highlighted session. |
| `alt+p`, `alt+shift+p` | Nudge it up or down, same as outside the picker. |
| `alt+z` | Step its snooze, same as outside the picker. |
| `alt+1`–`alt+5` | Rank it outright; `alt+3` is unranked. Picker only — outside it these switch tabs. |
| `ctrl+backspace` | Delete the previous word of the query. |
| `esc` | Close. |
```

and add after the table: "Snoozed rows show `zz HH:MM`, their wake time, dimmed and last in their rank."

"What alt+g does" — replace the paragraph starting "To go somewhere else deliberately, use the picker rather than demoting." with:

```
If it is still there and you have nothing to do in it, one of two things is
true. Its rank is stale, so lower it with `alt+shift+p`. Or it is waiting on
someone else — another agent's review, a human, an email — so snooze it with
`alt+z`. A snoozed session is out of the queue until its time is up, then counts
again; nothing announces it. The toast offers the demote and picker keys, read
from `config.toml`.
```

State-file table — add:

```
| `~/.local/state/herdr/agent-snooze` | Active snoozes: pane, wake time, step. |
| `~/.local/state/herdr/agent-priority.lock` | Serialises writes to both stores. |
```

- [ ] **Step 5: Validate**

Run: `sh -n ~/dotfiles/terminal/.config/herdr/herdr-agent-priority.sh && herdr config check && sh ~/dotfiles/tests/herdr-agent-priority/test.sh`
Expected: no syntax error, `Config: ok`, all tests `ok`.

- [ ] **Step 6: Commit**

```bash
cd ~/dotfiles
git add terminal/.config/herdr/herdr-agent-priority.sh terminal/.config/herdr/config.toml terminal/.config/herdr/README.md
git commit -m "herdr: picker keeps search with alt commands; alt+z snooze keybind

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_013eVjtaWhwxCpkrmZkWssH1"
```

---

### Task 9: Live verification

Everything here runs against the real session, so it needs a human at the keyboard for the key-routing parts. Snooze the test panes off again afterwards.

- [ ] **Step 1: Reload** — `herdr server reload-config` (the script is a symlink, so it is live already; only the keybind needs the reload).

- [ ] **Step 2: alt+z on a waiting agent** — toast "Snoozed 5m · until HH:MM"; `~/.config/herdr/herdr-agent-priority.sh list` no longer shows it; alt+g goes elsewhere. Press alt+z four more times: 30m, 2h, 4h, off.

- [ ] **Step 3: Picker** (`alt+space p`):
  - Type `pz 123` — all six characters land in the query.
  - alt+p / alt+shift+p / alt+z act on the highlighted row and the query stays.
  - After alt+shift+p re-sorts, the cursor is still on the same session. **If it is not**, stop and report it to the user rather than improvising: the likely cause is `--id-nth` indexing the displayed fields (`--with-nth=2..`) rather than the original line, and the fix is a design choice (e.g. tracking on the title column instead).
  - alt+1…alt+5 set ranks. **If they switch herdr tabs instead**, the popup is not receiving them; record that in the `pick)` comment and README and tell the user before choosing another binding.
  - ctrl+backspace deletes a word.
  - Snoozed rows show `zz HH:MM`, dimmed, last in their band.

- [ ] **Step 4: Report** results to the user, including any failed live check verbatim. Do not claim the key routing works without having seen it.
