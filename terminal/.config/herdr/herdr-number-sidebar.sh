#!/bin/sh
# Prefix herdr spaces, agents, and tabs with their keyboard number.
#
#   herdr-number-sidebar.sh [--no-tabs] [--clear]
#
# tmux numbers windows for free ("2: editor"); herdr does not. Its sidebar row
# tokens are a fixed set — state_icon, state_text, workspace, tab, agent,
# terminal_title, terminal_title_stripped, branch, git_status (read out of the
# binary; the documented list is not exhaustive) — and none of them is an index.
# So the number has to be injected.
#
# The point is not decoration. Each number is the DIGIT YOU PRESS:
#
#   space N   ctrl+alt+N   row position, per session
#   tab N     alt+N        row position, per space
#   agent N   prefix+N     row position, whole panel
#
# ALL THREE ARE POSITIONS. herdr's own config calls these "indexed bindings",
# and the index is where a thing sits in its list — NOT the .number field the
# same list also carries.
#
# This script used to stamp .number for spaces and tabs, and that was wrong.
# .number is a creation counter: it equals the digit in the id (w2:t4 -> 4) and
# it keeps its holes when something closes. So after closing tab 3 the labels
# read 1, 2, 4, 5, 6 while the keys that actually reach them are 1, 2, 3, 4, 5,
# and every tab past the hole was off by one. Confirmed against live state:
# w2's "4: selma-KB" was sitting at position 3.
#
# Spaces were stamped the same wrong way but never showed it — no space had
# been closed, so position and .number still agreed. Fixed here too rather than
# left as a trap for the first time a space is deleted.
#
# Positions past 9 get no prefix at all. alt+1..9 stops at nine, so a "10: " on
# a tab no digit can reach would be a worse lie than no number.
#
# Two mechanisms, and they are not equally safe:
#
#   Spaces and agents use `report-metadata --token`, a display-only side
#   channel. Nothing user-owned is touched, and --clear removes it completely.
#
#   Tabs have no metadata channel, so their number has to go into the label
#   itself — real, user-owned data. That is why --no-tabs exists. The rename is
#   idempotent (any existing "N: " prefix is stripped before the current number
#   is applied, so numbers follow tabs that move), and tabs still carrying their
#   auto-generated numeric name are skipped, since "3" would become "3: 3".
set -eu

SOURCE=sidebar-numbers
do_tabs=1
clear=0
for a in "$@"; do
  case $a in
    --no-tabs) do_tabs=0 ;;
    --clear)   clear=1 ;;
    *) echo "usage: $0 [--no-tabs] [--clear]" >&2; exit 2 ;;
  esac
done

# --- spaces: row position, matches ctrl+alt+N ---
herdr workspace list | jq -r '.result.workspaces | to_entries[] | "\(.value.workspace_id) \(.key + 1)"' |
while read -r id n; do
  if [ "$clear" = 1 ] || [ "$n" -gt 9 ]; then
    herdr workspace report-metadata "$id" --source "$SOURCE" --clear-token idx >/dev/null
  else
    herdr workspace report-metadata "$id" --source "$SOURCE" --token "idx=$n:" >/dev/null
  fi
done

# --- agents: row position, matches prefix+N ---
# Deliberately the list index rather than any id: focus_agent addresses rows in
# panel order, so a pane number would point at the wrong row.
herdr agent list | jq -r '.result.agents | to_entries[] | "\(.value.pane_id) \(.key + 1)"' |
while read -r id n; do
  if [ "$clear" = 1 ] || [ "$n" -gt 9 ]; then
    herdr pane report-metadata "$id" --source "$SOURCE" --clear-token idx >/dev/null
  else
    herdr pane report-metadata "$id" --source "$SOURCE" --token "idx=$n:" >/dev/null
  fi
done

[ "$do_tabs" = 1 ] || exit 0

# --- tabs: row position within their own space, rewrites the label ---
# group_by(.workspace_id) is load-bearing: alt+N counts from the top of the
# space you are looking at, so the index has to restart per space. Sorting by
# .number inside each group is safe — it is a creation counter, so it is always
# ascending in display order even where it has holes.
herdr tab list | jq -r '
  .result.tabs
  | group_by(.workspace_id)[]
  | sort_by(.number)
  | to_entries[]
  | "\(.value.tab_id)\t\(.key + 1)\t\(.value.label)"' |
while IFS='	' read -r id n label; do
  bare=$(printf '%s' "$label" | sed -E 's/^[0-9]+: //')

  # An all-digit name is herdr's placeholder for an unnamed tab; leave it be.
  case $bare in ''|*[!0-9]*) ;; *) continue ;; esac

  if [ "$clear" = 1 ] || [ "$n" -gt 9 ]; then want=$bare; else want="$n: $bare"; fi
  [ "$want" = "$label" ] || herdr tab rename "$id" "$want" >/dev/null
done
