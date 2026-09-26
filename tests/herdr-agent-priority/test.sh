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
