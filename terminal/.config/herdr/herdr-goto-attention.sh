#!/bin/sh
# Jump to the next agent that wants something from you.
#
#   herdr-goto-attention.sh [--dry-run]
#
# herdr can cycle agents (previous_agent/next_agent) and jump to one by index
# (focus_agent), but it has no "take me to whoever is waiting" action unless you
# flip ui.agent_panel_sort to "priority" — which reorders the whole sidebar and
# throws away the space grouping. This gets the same jump while leaving the
# panel alone.
#
# Queue order is blocked first, then done. They are different asks: blocked
# means an agent is stopped waiting on you (permission prompt, question), done
# means it finished while you were looking elsewhere. Blocked is the one costing
# you wall-clock time, so it always wins; done is only offered once no agent is
# stuck. Never selects idle or working — those want nothing.
#
# Repeated presses cycle within the current queue: the focused agent's position
# is looked up and we advance one, wrapping. Reading `focused` from the list
# rather than HERDR_ACTIVE_PANE_ID keeps this correct however it is invoked.
# When nothing needs attention it exits silently, leaving focus untouched.
set -eu

target=$(herdr agent list | jq -r '
  [ .result.agents[] | select(.agent_status == "blocked") ] as $blocked
  | [ .result.agents[] | select(.agent_status == "done")  ] as $done
  | (if ($blocked | length) > 0 then $blocked else $done end) as $queue
  | if ($queue | length) == 0 then empty
    else ($queue | map(.focused) | index(true)) as $i
      | $queue[ (($i // -1) + 1) % ($queue | length) ].pane_id
    end
')

[ -n "$target" ] || exit 0
[ "${1:-}" = "--dry-run" ] && { echo "$target"; exit 0; }

# `herdr agent focus` alone does NOT move the client. agent.focus is not in the
# server's client-shell method allowlist, so it updates server state and the
# attached client overwrites it a second later — which is why this script has
# been quietly doing nothing. workspace.focus and tab.focus are client-routed,
# so the three together actually move the view. Same fix as in
# herdr-agent-priority.sh, which see for the measurement.
row=$(herdr pane list | jq -r --arg p "$target" \
  'first(.result.panes[] | select(.pane_id == $p) | "\(.workspace_id) \(.tab_id)") // empty')
herdr agent focus "$target" >/dev/null 2>&1 || true
if [ -n "$row" ]; then
  herdr workspace focus "${row%% *}" >/dev/null 2>&1 || true
  herdr tab focus "${row#* }" >/dev/null 2>&1 || true
fi
