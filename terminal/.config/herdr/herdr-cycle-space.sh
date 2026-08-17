#!/bin/sh
# Cycle herdr spaces (workspaces) forward or backward, wrapping at the ends.
#
#   herdr-cycle-space.sh next|prev
#
# herdr has no CLI verb for cyclic workspace movement — `workspace focus`
# requires an explicit ID — and its keybinding system allows only one key per
# action, with previous_workspace/next_workspace already spent on ctrl+alt+
# up/down. This bridges the gap so the Tab gesture can coexist with the arrows.
#
# Reads `focused` straight from the workspace list rather than trusting
# HERDR_ACTIVE_WORKSPACE_ID, so it behaves correctly no matter how it is
# invoked. jq's negative array indexing gives us wrap-around for free.
set -eu

dir="${1:-next}"

target=$(herdr workspace list | jq -r --arg dir "$dir" '
  .result.workspaces as $w
  | ($w | map(.focused) | index(true)) as $i
  | if $i == null or ($w | length) < 2 then empty
    else $w[ (if $dir == "prev" then $i - 1 else $i + 1 end) % ($w | length) ].workspace_id
    end
')

[ -n "$target" ] && exec herdr workspace focus "$target" >/dev/null
