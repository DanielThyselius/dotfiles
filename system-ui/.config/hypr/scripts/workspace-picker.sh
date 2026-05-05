#!/usr/bin/env bash
# Pick a workspace via walker (dmenu mode) and dispatch a switch.
# Lists workspaces 1-9 plus any other workspaces that currently have windows,
# annotated with the apps living there and an arrow on the active workspace.

set -euo pipefail

current=$(hyprctl activeworkspace -j | jq -r '.id')

# Map: workspace id -> "app1, app2"
mapfile -t lines < <(
  hyprctl clients -j | jq -r '
    [.[] | select(.workspace.id > 0) | {ws: .workspace.id, class: .class}]
    | group_by(.ws)
    | map({ws: .[0].ws, apps: ([.[] | .class] | map(select(. != "")) | unique | join(", "))})
    | sort_by(.ws)[]
    | "\(.ws)\t\(.apps)"
  '
)

declare -A apps_by_ws
for line in "${lines[@]}"; do
  ws=${line%%$'\t'*}
  apps=${line#*$'\t'}
  apps_by_ws[$ws]=$apps
done

# Union of {1..9} and any populated workspaces, deduped, numerically sorted
mapfile -t ids < <(
  { printf '%s\n' {1..9}; printf '%s\n' "${!apps_by_ws[@]}"; } \
    | sort -un
)

build_line() {
  local id=$1 apps=${apps_by_ws[$1]:-} marker=" "
  [[ $id == "$current" ]] && marker="→"
  if [[ -n $apps ]]; then
    printf '%s %s  %s\n' "$marker" "$id" "$apps"
  else
    printf '%s %s\n' "$marker" "$id"
  fi
}

menu=""
for id in "${ids[@]}"; do menu+="$(build_line "$id")"$'\n'; done

selected=$(printf '%s' "$menu" | walker --dmenu -p "Workspace" || true)
[[ -z $selected ]] && exit 0

# Extract leading id (after the marker)
ws=$(awk '{print $2}' <<<"$selected")
[[ $ws =~ ^[0-9]+$ ]] && hyprctl dispatch workspace "$ws"
