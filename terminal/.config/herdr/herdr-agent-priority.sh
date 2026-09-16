#!/bin/sh
# Rank the agents that are waiting on you, and jump to the top of that ranking.
#
#   herdr-agent-priority.sh up [pane_id]      raise one step, stops at 5
#   herdr-agent-priority.sh down [pane_id]    lower one step, stops at 1
#   herdr-agent-priority.sh set <1-5> [pane_id]
#   herdr-agent-priority.sh clear [pane_id]
#   herdr-agent-priority.sh goto              focus the next highest-priority waiting agent
#   herdr-agent-priority.sh pick              ranked picker, for the popup plugin pane
#   herdr-agent-priority.sh rows              the picker's rows, also fzf's reload source
#   herdr-agent-priority.sh stamp             re-apply every stored priority (startup hook)
#   herdr-agent-priority.sh list              show the queue goto walks, in order
#
# THE POINT. With 30-odd agents the sidebar tells you *that* things want you,
# never *which* to do first, so the fleet becomes a treadmill: you service
# whoever finished last. A number you set once, when you start the session, lets
# you work top down and spend the day on what matters. Priority 1 work never
# getting reached is the feature, not a bug — it is the signal to close it.
#
# THREE IS UNSET, DELIBERATELY. up and down step through 1..5 and clamp at the
# ends, and landing on 3 removes the token rather than writing "P3". Unset
# already sorts as 3, so the two states mean the same thing, and not stamping it
# keeps thirty-odd unranked rows clean instead of labelling every one of them
# with a number that says nothing.
#
# WHY A STORE AND NOT JUST THE TOKEN. The priority is displayed as a pane
# metadata token ($pri in [ui.sidebar.agents]), a display-only side channel that
# sits alongside the live session title instead of overwriting anything. But
# herdr resets metadata tokens on session restore — persist/restore.rs rebuilds
# them as MetadataTokens::default() — so the token alone would evaporate on
# every restart. The file below is the truth; the token is a projection of it,
# re-stamped by the agent-priority plugin's startup hook.
#
# WHY NOT THE PANE LABEL. A label would survive restarts on its own and would
# also show up in the prefix+g navigator, which a token does not. It was still
# the wrong field: the label is what the sidebar falls back to for the task
# title, so writing a priority into it would freeze "Smarticipate open PRs
# review" at whatever it said when you pressed the key, and that title keeps
# changing while the agent works. A stale title costs more than navigator
# filtering buys.
#
# LOOP HAZARD, same as herdr-number-sidebar.sh: report-metadata fires
# pane.updated and *.metadata_updated. The plugin must never hook those events,
# and it does not — startup only.
set -eu

SOURCE=agent-priority
DEFAULT=3
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr"
STORE="$STATE_DIR/agent-priority"

mkdir -p "$STATE_DIR"
[ -f "$STORE" ] || : >"$STORE"

die() { echo "$*" >&2; exit 2; }

focused_pane() {
  herdr agent list | jq -r 'first(.result.agents[] | select(.focused) | .pane_id) // empty'
}

# Resolve the pane a set/up/down/clear applies to: explicit argument, else the
# focused one. Read from the agent list rather than $HERDR_PANE_ID so the same
# script works from a keybind, a plugin action and a shell inside some other
# pane.
target_pane() {
  if [ -n "${1:-}" ]; then
    printf '%s\n' "$1"
  else
    focused_pane
  fi
}

stored() { awk -F'\t' -v p="$1" '$1 == p { print $2; exit }' "$STORE"; }

store_set() { # store_set <pane_id> <priority|"">
  tmp=$(mktemp "$STORE.XXXXXX")
  awk -F'\t' -v p="$1" '$1 != p' "$STORE" >"$tmp"
  if [ -n "$2" ]; then printf '%s\t%s\n' "$1" "$2" >>"$tmp"; fi
  mv "$tmp" "$STORE"
}

stamp_one() { # stamp_one <pane_id> <priority|"">
  if [ -n "$2" ]; then
    herdr pane report-metadata "$1" --source "$SOURCE" --token "pri=P$2" >/dev/null
  else
    herdr pane report-metadata "$1" --source "$SOURCE" --clear-token pri >/dev/null
  fi
}

apply() { # apply <pane_id> <priority|"">
  store_set "$1" "$2"
  stamp_one "$1" "$2"
}

# The queue goto walks. Highest priority first; within a band, blocked before
# done, because a blocked agent is usually one keystroke away from running again
# and costs you seconds rather than a review; then longest-waiting first.
#
# Only blocked and done are candidates. Working agents want nothing and idle
# ones have already been dealt with.
queue() {
  herdr agent list | jq -r --argjson def "$DEFAULT" '
    [ .result.agents[]
      | select(.agent_status == "blocked" or .agent_status == "done")
      | { pane_id,
          focused,
          status: .agent_status,
          title: (.terminal_title_stripped // .terminal_title // ""),
          pri: (((.tokens.pri // "") | ltrimstr("P") | tonumber?) // $def) } ]
    | sort_by(-.pri, (if .status == "blocked" then 0 else 1 end))
    | .[]
    | [ .pane_id, (.pri | tostring), .status, (if .focused then "*" else "-" end), .title ]
    | @tsv'
}

# Every agent, ranked, for the picker. Unlike queue() this keeps working and
# idle sessions in the list: the picker is the view of *everything you have on*,
# which is the question "what should I be doing" actually needs. Ranked first,
# then blocked, done, working, idle within a band.
#
# Field 1 is the pane id and stays hidden in fzf; field 2 is the whole display
# line, pre-padded here because jq cannot pad.
rows() {
  herdr agent list | jq -r --argjson def "$DEFAULT" '
    [ .result.agents[]
      | { pane_id,
          focused,
          status: .agent_status,
          workspace: .workspace_id,
          title: (.terminal_title_stripped // .terminal_title // ""),
          ranked: (((.tokens.pri // "") | length) > 0),
          pri: (((.tokens.pri // "") | ltrimstr("P") | tonumber?) // $def) } ]
    | sort_by(-.pri,
        (if .status == "blocked" then 0
         elif .status == "done" then 1
         elif .status == "working" then 2
         else 3 end))
    | .[]
    | [ .pane_id,
        (if .ranked then "P\(.pri)" else "--" end),
        .status,
        .workspace,
        (if .focused then ">" else " " end),
        .title ]
    | @tsv' |
    awk -F'\t' '{ printf "%s\t%s %-2s %-7s %-3s %s\n", $1, $5, $2, $3, $4, $6 }'
}

SELF="$HOME/.config/herdr/herdr-agent-priority.sh"

cmd=${1:-}
[ -n "$cmd" ] || die "usage: $0 {up|down|set <1-5>|clear|goto|pick|rows|stamp|list} [pane_id]"
shift

case $cmd in
up | down)
  pane=$(target_pane "${1:-}")
  [ -n "$pane" ] || exit 0
  cur=$(stored "$pane")
  case $cur in 1 | 2 | 3 | 4 | 5) ;; *) cur=$DEFAULT ;; esac
  if [ "$cmd" = up ]; then
    next=$((cur + 1))
    [ "$next" -le 5 ] || next=5
  else
    next=$((cur - 1))
    [ "$next" -ge 1 ] || next=1
  fi
  [ "$next" != "$DEFAULT" ] || next=''
  apply "$pane" "$next"
  ;;

set)
  n=${1:-}
  case $n in
  1 | 2 | 3 | 4 | 5) ;;
  *) die "priority must be 1-5" ;;
  esac
  pane=$(target_pane "${2:-}")
  [ -n "$pane" ] || exit 0
  apply "$pane" "$n"
  ;;

clear)
  pane=$(target_pane "${1:-}")
  [ -n "$pane" ] || exit 0
  apply "$pane" ""
  ;;

goto)
  # Repeated presses walk down the queue: find where the focused pane sits and
  # advance one, wrapping. Reading `focused` out of the queue itself keeps that
  # correct no matter how the script was invoked.
  target=$(queue | awk -F'\t' '
    { pane[NR] = $1; if ($4 == "*") here = NR }
    END { if (NR) print pane[(here % NR) + 1] }')
  [ -n "$target" ] || exit 0
  exec herdr agent focus "$target" >/dev/null
  ;;

rows)
  rows
  ;;

pick)
  # Runs inside the plugin popup, which gets every keystroke including Escape.
  # 1-5 re-rank the highlighted row in place and reload the list, so the popup
  # is both the view and the way to set a priority without leaving it.
  command -v fzf >/dev/null || die "pick needs fzf"
  sel=$(rows | fzf \
    --delimiter='\t' --with-nth=2.. --no-sort --cycle \
    --prompt='agent > ' \
    --header='enter jump  ·  1-5 rank  ·  0 unrank  ·  esc close' \
    --bind="1:execute-silent($SELF set 1 {1})+reload($SELF rows)" \
    --bind="2:execute-silent($SELF set 2 {1})+reload($SELF rows)" \
    --bind="3:execute-silent($SELF clear {1})+reload($SELF rows)" \
    --bind="4:execute-silent($SELF set 4 {1})+reload($SELF rows)" \
    --bind="5:execute-silent($SELF set 5 {1})+reload($SELF rows)" \
    --bind="0:execute-silent($SELF clear {1})+reload($SELF rows)" || true)
  [ -n "$sel" ] || exit 0
  target=$(printf '%s\n' "$sel" | cut -f1)
  [ -n "$target" ] || exit 0
  # Focus straight from inside the popup. A popup is not a Herdr pane and does
  # not take part in focus at all, so the change lands on the session underneath
  # and survives the popup closing. Backgrounding this instead does NOT work:
  # exiting is what closes the popup, and the orphan is SIGHUPped with the pty
  # before a delay elapses.
  herdr agent focus "$target" >/dev/null
  ;;

stamp)
  # Startup hook. Re-projects the store onto metadata tokens after a restore
  # wiped them, and drops entries whose pane is gone so the file cannot grow
  # without bound.
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
  ;;

list)
  queue | awk -F'\t' '{ printf "P%s  %-8s %-8s %s %s\n", $2, $3, $1, ($4 == "*" ? ">" : " "), $5 }'
  ;;

*)
  die "unknown command: $cmd"
  ;;
esac
