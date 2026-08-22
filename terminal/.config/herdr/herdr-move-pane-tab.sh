#!/bin/sh
# Move the focused pane into the adjacent tab, wrapping at the ends.
#
#   herdr-move-pane-tab.sh left|right
#
# herdr has no native action for relocating a pane across tabs — the whole
# feature is CLI-only (`herdr pane move`), and that verb takes an explicit
# pane id, so there is nothing to bind directly. tmux's equivalent is
# `join-pane -t :-` / `:+`, which likewise has no herdr counterpart.
#
# Two things the CLI usage line insists on, learned the hard way:
#   --split is MANDATORY alongside --tab (it is optional-looking in --help but
#   the command exits 5 without it). right/0.5 matches split_vertical and
#   tmux's join-pane -h.
#   --focus is what makes repeated presses push the SAME pane along the tab
#   row. Without it the second press would grab whatever pane you were left
#   looking at instead.
#
# Reads `focused` straight from the pane list rather than trusting
# HERDR_ACTIVE_PANE_ID, matching herdr-cycle-space.sh, so it behaves correctly
# no matter how it is invoked. Moving a tab's last pane collapses the source
# tab — that is a merge, not a bug.
set -eu

dir="${1:-right}"

focused=$(herdr pane list | jq -c '.result.panes[] | select(.focused == true)')
[ -n "$focused" ] || exit 0

pane=$(printf '%s' "$focused" | jq -r .pane_id)
tab=$(printf '%s' "$focused" | jq -r .tab_id)
ws=$(printf '%s' "$focused" | jq -r .workspace_id)

target=$(herdr tab list --workspace "$ws" | jq -r --arg dir "$dir" --arg tab "$tab" '
  (.result.tabs | sort_by(.number)) as $t
  | ($t | map(.tab_id) | index($tab)) as $i
  | if $i == null or ($t | length) < 2 then empty
    else $t[ (if $dir == "left" then $i - 1 else $i + 1 end) % ($t | length) ].tab_id
    end
')

[ -n "$target" ] && exec herdr pane move "$pane" --tab "$target" --split right --focus >/dev/null
