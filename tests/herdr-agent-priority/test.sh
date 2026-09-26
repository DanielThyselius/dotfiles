#!/bin/sh
# Offline tests for herdr-agent-priority.sh.
#
#   sh tests/herdr-agent-priority/test.sh
#
# A stub `herdr` on PATH serves agents.json; HOME and XDG_STATE_HOME point at a
# temp dir, so nothing reaches the live session — set_view's socket lives under
# $HOME and simply is not there. HERDR_SOCKET_PATH is also pointed at a temp
# path that never exists, so a stray call that bypasses the stub (or a helper
# that talks to the socket directly) fails instead of reaching the live
# session. The stub's tokens never change after a write, so rank assertions
# read the store file, not a later `agent list`.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SCRIPT="$REPO/terminal/.config/herdr/herdr-agent-priority.sh"
CONFIG="$REPO/terminal/.config/herdr/config.toml"
PATH="$HERE/bin:$PATH"
export PATH

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

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
  T=$(mktemp -d "$ROOT/t.XXXXXX")
  HOME="$T/home"
  XDG_STATE_HOME="$T/state"
  FIXTURE_DIR="$T/fx"
  HERDR_CONFIG_PATH="$CONFIG"
  export HOME XDG_STATE_HOME FIXTURE_DIR HERDR_CONFIG_PATH
  unset AGENT_PRIORITY_CRIT_DELAY 2>/dev/null || true
  # Strip anything that could point this run at a real herdr session, so a
  # call that slips past the stub fails loudly instead of reaching it.
  unset HERDR_SOCKET_PATH HERDR_BIN_PATH HERDR_PANE_ID HERDR_TAB_ID \
    HERDR_WORKSPACE_ID HERDR_ENV XDG_CONFIG_HOME 2>/dev/null || true
  HERDR_SOCKET_PATH="$T/none.sock"
  export HERDR_SOCKET_PATH
  mkdir -p "$HOME" "$FIXTURE_DIR"
  cp "$HERE/agents.json" "$FIXTURE_DIR/agents.json"
  : >"$FIXTURE_DIR/toasts.log"
  : >"$FIXTURE_DIR/metadata.log"
  : >"$FIXTURE_DIR/calls.log"
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
  "-- Top of the ranking alpha" \
  "$(sed 's/.* -- /-- /' "$FIXTURE_DIR/toasts.log")"

# --- lock: concurrent nudges are not lost ------------------------------------
setup
AGENT_PRIORITY_CRIT_DELAY=0.3
export AGENT_PRIORITY_CRIT_DELAY
run up w1:p2 & run up w1:p2 & run up w1:p2 & wait
check "three concurrent ups from unranked land on 5" \
  "w1:p2	5" "$(cat "$(state agent-priority)")"

# The metadata stamp is inside the lock (Task 2 Step 7's spec change), so the
# sidebar token is written in the same order as the store: 4, then 5, then 5
# again. Stamped outside the lock, the three processes' `report-metadata`
# calls would race independently of their store writes and could land as
# 4 5 5, 5 4 5 or any other order — this would have failed against that bug.
check "metadata stamps land in store-write order (4 5 5)" \
  "4 5 5" \
  "$(grep -o 'prisort=[0-9]*' "$FIXTURE_DIR/metadata.log" | cut -d= -f2 | tr '\n' ' ' | sed 's/ $//')"

# --- explicit pane ids are validated -----------------------------------------
setup
code=0; sh "$SCRIPT" up w9:nope || code=$?
check "up on an unknown pane exits 0" "0" "$code"
check "up on an unknown pane writes nothing" "" "$(cat "$(state agent-priority)")"
check "no metadata written for unknown pane" "" "$(cat "$FIXTURE_DIR/metadata.log")"
check "no toast sent for unknown pane" "" "$(cat "$FIXTURE_DIR/toasts.log")"
check "logs that pane was not live" "yes" \
  "$(grep -qF 'not a live agent: w9:nope' "$(state agent-priority.log)" && echo yes || echo no)"

# --- snooze ladder -------------------------------------------------------------
# Tolerant of a missing store: a script that dies before creating one must
# show up here as a FAIL on the assertion, not an aborted runner.
snooze_step_of() { awk -F'\t' -v p="$1" '$1 == p { print $3 }' "$(state agent-snooze)" 2>/dev/null || true; }

setup
steps=''
for _ in 1 2 3 4 5; do
  run snooze w1:p1
  steps="$steps $(snooze_step_of w1:p1)"
done
check "snooze ladder 5,30,120,240,off" " 5 30 120 240 " "$steps"
check "snooze toast names duration" "yes" \
  "$(grep -qF 'Snoozed 5m' "$FIXTURE_DIR/toasts.log" && echo yes || echo no)"
check "fifth press's toast is the off rung" "yes" \
  "$(tail -n1 "$FIXTURE_DIR/toasts.log" | grep -qF 'Snooze off' && echo yes || echo no)"

setup
before=$(date +%s)
run snooze w1:p1
wake=$(awk -F'\t' '$1 == "w1:p1" { print $2 }' "$(state agent-snooze)" 2>/dev/null || true)
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
mkdir -p "$XDG_STATE_HOME/herdr"
printf 'w1:p2\textra\t%s\t30\n' $(( $(date +%s) + 600 )) >"$(state agent-snooze)"
printf 'w1:p4\t%s\t30\n' $(( $(date +%s) + 100000 )) >>"$(state agent-snooze)"
run snooze w1:p1
check "a 4-field line and a wake past the 4h cap are dropped, not carried as snoozed" \
  "w1:p1" "$(awk -F'\t' '{ print $1 }' "$(state agent-snooze)" | tr '\n' ' ' | sed 's/ $//')"

setup
mkdir -p "$XDG_STATE_HOME/herdr"
printf 'w1:p4\t%s\t30\n' $(( $(date +%s) - 1 )) >"$(state agent-snooze)"
printf 'w1:p2\t%s\t15\n' $(( $(date +%s) + 600 )) >>"$(state agent-snooze)"
run snooze w1:p1
check "pruning drops an expired line and an off-ladder line for other panes too" \
  "w1:p1" "$(awk -F'\t' '{ print $1 }' "$(state agent-snooze)" | tr '\n' ' ' | sed 's/ $//')"

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
# Base fixture as-is: w1:p2 (idle, P3) is focused, outside the P5 band, so
# goto's "step off the currently-focused band member" logic can't produce
# w1:p4 on its own — only the queue-level snooze filter can. Without the
# filter, goto from outside the band lands on the band's first member, the
# snoozed w1:p1, which discriminates this from the earlier (fixture-forced)
# version of the test that passed even pre-fix.
run snooze w1:p1
run goto
check "goto from outside the band skips the snoozed pane" "yes" \
  "$(grep -q 'goto focusing w1:p4' "$(state agent-priority.log)" && echo yes || echo no)"
check "goto actually focused w1:p4" "yes" \
  "$(grep -qF 'agent focus w1:p4' "$FIXTURE_DIR/calls.log" && echo yes || echo no)"
check "goto did not focus the snoozed pane" "no" \
  "$(grep -qF 'agent focus w1:p1' "$FIXTURE_DIR/calls.log" && echo yes || echo no)"

setup
# w1:p10 is a substring hazard for the naive `inside` check the code comment
# warns about: if the filter matched "w1:p1" as a substring, snoozing w1:p1
# would also (wrongly) hide w1:p10.
fixture '.result.agents += [{"pane_id":"w1:p10","focused":false,"agent_status":"done","terminal_title":"kappa","terminal_title_stripped":"kappa","state_change_seq":50,"tokens":{"pri":"P5","prisort":"5"},"workspace_id":"w1","tab_id":"w1:t1"}]'
run snooze w1:p1
check "w1:p10 is not caught as a substring of the snoozed w1:p1" \
  "w1:p4 w1:p10 w1:p2" "$(queue_ids)"

setup
run snooze w1:p1
run snooze w1:p2
run snooze w1:p4
run goto
check "goto toasts when everything waiting is snoozed" "yes" \
  "$(tail -n1 "$FIXTURE_DIR/toasts.log" | grep -qF 'Everything waiting is snoozed' && echo yes || echo no)"
check "goto with an all-snoozed queue never calls agent focus" "no" \
  "$(grep -qF 'agent focus' "$FIXTURE_DIR/calls.log" && echo yes || echo no)"

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

# --- stamp prunes the rank store ---------------------------------------------
setup
mkdir -p "$XDG_STATE_HOME/herdr"
{
  printf 'w1:p1\t5\n'
  printf 'w9:gone\t5\n'
} >"$(state agent-priority)"
run stamp
check "stamp keeps only live ranks" "w1:p1" "$(cut -f1 "$(state agent-priority)")"

# --- stamp reconciles prisort only where it is wrong -------------------------
# Base fixture: w1:p1/p3/p4 already carry prisort=5, w1:p2 carries prisort=3.
# With an empty rank store every one of them is "wrong" except w1:p2, which
# already reads the unranked default (3) that an empty store implies — so
# only p1, p3, p4 should get a fresh report-metadata call.
setup
run stamp
check "reconcile restamps exactly the mismatched panes" "w1:p1 w1:p3 w1:p4" \
  "$(awk '{ print $3 }' "$FIXTURE_DIR/metadata.log" | tr '\n' ' ' | sed 's/ $//')"
check "reconcile never touches the pane already at the default" "no" \
  "$(grep -qF 'w1:p2' "$FIXTURE_DIR/metadata.log" && echo yes || echo no)"

# --- stamp never prunes on a bad or empty pane list --------------------------
# A herdr that is down or briefly returns no panes must never read as "every
# pane is gone": pane.agent_detected fires this hook constantly, so without a
# guard a transient failure would wipe both stores and clear every visible
# rank, silently. Pre-guard, all three of these failed with the seeded lines
# gone and metadata written; confirmed by reverting the guard locally before
# writing this comment.
for mode in exit errjson empty; do
  setup
  mkdir -p "$XDG_STATE_HOME/herdr"
  printf 'w1:p1\t5\n' >"$(state agent-priority)"
  printf 'w1:p1\t%s\t5\n' $(( $(date +%s) + 600 )) >"$(state agent-snooze)"
  HERDR_STUB_FAIL_PANE_LIST=$mode run stamp
  check "stamp ($mode pane list) leaves the rank store untouched" \
    "w1:p1	5" "$(cat "$(state agent-priority)")"
  check "stamp ($mode pane list) leaves the snooze store untouched" \
    "yes" "$(cut -f1 "$(state agent-snooze)" | grep -qx 'w1:p1' && echo yes || echo no)"
  check "stamp ($mode pane list) writes no metadata" \
    "" "$(cat "$FIXTURE_DIR/metadata.log")"
done

exit "$failed"
