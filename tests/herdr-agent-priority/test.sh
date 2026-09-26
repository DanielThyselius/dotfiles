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

exit "$failed"
