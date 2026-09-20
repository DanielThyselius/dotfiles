#!/bin/sh
# Move the focused pane to ANY tab, in any space, chosen from a picker.
#
#   herdr-move-pane-picker.sh open    open the picker and act on its choice
#   herdr-move-pane-picker.sh pick    the picker itself, run inside the popup
#   herdr-move-pane-picker.sh rows    the picker's rows (also the way to eyeball
#                                     the list without opening a popup)
#
# The sideways relatives of this key are herdr-move-pane-tab.sh (adjacent tab,
# ctrl+alt+shift+arrows) and alt+shift+t (break out to a new tab). Both walk a
# known destination. This one answers "put it over THERE", where there is any
# of ~30 tabs spread across ten spaces — the case the arrow keys cannot reach
# without pressing them eleven times, and the one prefix+g refuses to serve:
# the navigator is focus-only. It has no move verb, no config action exists for
# one (keys.* has move_tab_*, which reorders TABS), and the pane right-click
# menu stops at swap/split/zoom. `herdr pane move` is the whole feature.
#
# WHY A PLUGIN POPUP AND NOT type = "popup". A custom-command popup would be one
# config block and no plugin, but the move has to happen AFTER the popup closes.
# Focusing from inside a popup does not stick — the session puts focus back
# where it was as the popup goes away (the same wall herdr-agent-priority.sh
# hit, measured there, and its two-stage open/pick shape is copied here). So the
# keybind runs `open`, which is a child of the server and outlives the popup:
# it parks the choice in a file, waits for the popup to die, then moves.
#
# THE SOURCE PANE IS CAPTURED BEFORE THE POPUP OPENS, into a context file the
# popup reads back. The popup needs it for the prompt and to hide the tab the
# pane is already in, and HERDR_PANE_ID is deliberately absent from a popup's
# environment ("a popup has no pane ID"), so passing it forward is the only
# route that does not guess.
#
# THINGS THE CLI INSISTS ON, all three learned by watching it fail:
#   --split is MANDATORY next to --tab. Without it the command exits 5.
#   Moving into the tab you are already in is a no-op: {"changed": false,
#   "reason": "same_tab"}. Hence the row for the current tab being dropped.
#   A zoomed source or target tab refuses the same way, with "zoomed_tab" —
#   that one is reported as a toast, because it looks like nothing happened.
#
# CROSS-SPACE MOVES RENAME THE PANE. The process and terminal survive, but the
# pane gets a fresh public id in the destination space (measured: wC:p1 arrived
# as wD:p2). So the follow-the-pane focus below reads the id out of the move
# response instead of reusing the one it sent.
set -eu

PLUGIN=pane-mover
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr"
SELECTION="$STATE_DIR/pane-mover.selection"
SOURCE_FILE="$STATE_DIR/pane-mover.source"
LOG="$STATE_DIR/pane-mover.log"
NOTIFY_ID="$STATE_DIR/pane-mover.notify-id"

mkdir -p "$STATE_DIR"

die() { echo "$*" >&2; exit 2; }

# Keybind commands are spawned by the server with no terminal attached, so a
# failure here is otherwise completely silent. Same log discipline as
# herdr-agent-priority.sh, including the trim.
log() {
  printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || return 0
  if [ "$(wc -l <"$LOG" 2>/dev/null || echo 0)" -gt 200 ]; then
    tail -n 100 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
}

# Replace rather than stack: quickshell honours replaces_id, not the
# x-canonical-private-synchronous hint. See herdr-agent-priority.sh for why
# this is notify-send and not `herdr notification show`.
toast() { # toast <title> <body>
  command -v notify-send >/dev/null 2>&1 || return 0
  prev=$(cat "$NOTIFY_ID" 2>/dev/null || true)
  case $prev in '' | *[!0-9]*) prev=0 ;; esac
  id=$(notify-send --app-name=herdr --expire-time=2500 --print-id \
    --replace-id="$prev" -- "$1" "$2" 2>/dev/null) || return 0
  case $id in '' | *[!0-9]*) ;; *) printf '%s\n' "$id" >"$NOTIFY_ID" ;; esac
}

# Focus a pane so the CLIENT actually moves. agent.focus alone is server-side
# only and gets overwritten within a second; workspace.focus and tab.focus are
# on the client-shell allowlist and drag the view along. The trio is lifted
# wholesale from herdr-agent-priority.sh, where the reasoning is spelled out.
focus_pane() { # focus_pane <pane_id>
  row=$(herdr pane list | jq -r --arg p "$1" \
    'first(.result.panes[] | select(.pane_id == $p) | "\(.workspace_id) \(.tab_id)") // empty')
  [ -n "$row" ] || return 0
  herdr agent focus "$1" >/dev/null 2>&1 || true
  herdr workspace focus "${row%% *}" >/dev/null 2>&1 || true
  herdr tab focus "${row#* }" >/dev/null 2>&1 || true
}

# Every destination herdr can take, as TSV: field 1 is the machine spec and
# stays hidden in fzf, field 2 is what you read.
#
# Order is "near things first": the space you are in, then the rest in sidebar
# order, each space's tabs followed by its own "new tab" row so breaking out
# next door is one row away from moving next door. New space goes last — it is
# the least common and the most disruptive.
rows() { # rows [current_tab_id] [current_workspace_id]
  cur_tab=${1:-}
  cur_ws=${2:-}
  jq -nr \
    --argjson ws "$(herdr workspace list)" \
    --argjson tabs "$(herdr tab list)" \
    --arg cur "$cur_tab" --arg curws "$cur_ws" '
    ($ws.result.workspaces | map({key: .workspace_id, value: .}) | from_entries) as $w
    | ($tabs.result.tabs | group_by(.workspace_id)
       | map({ws: .[0].workspace_id, tabs: sort_by(.number)})
       | sort_by((if .ws == $curws then 0 else 1 end), ($w[.ws].number // 9999))) as $groups
    | [ $groups[]
        | ($w[.ws].label // .ws) as $label
        | ( .tabs[]
            | select(.tab_id != $cur)
            | ["tab:" + .tab_id,
               "\($label) ▸ \(.label)  ·  \(.pane_count)p"] ),
          ["newtab:" + .ws, "\($label) ▸ ＋ new tab"] ]
      + [["newspace:", "＋ new space"]]
    | .[] | @tsv'
}

cmd=${1:-}
[ -n "$cmd" ] || die "usage: $0 {open|pick|rows}"

case $cmd in
rows)
  rows "${2:-}" "${3:-}"
  ;;

pick)
  # Runs inside the popup, which gets every keystroke including Escape.
  # --expect turns the accepting key into the first output line, which is how
  # one list serves both split directions without a second binding.
  command -v fzf >/dev/null || die "pick needs fzf"
  src=$(cat "$SOURCE_FILE" 2>/dev/null || true)
  [ -n "$src" ] || exit 0
  cur_tab=$(printf '%s' "$src" | cut -f2)
  cur_ws=$(printf '%s' "$src" | cut -f3)
  title=$(printf '%s' "$src" | cut -f4)
  [ -n "$title" ] || title=$(printf '%s' "$src" | cut -f1)

  out=$(rows "$cur_tab" "$cur_ws" | fzf \
    --delimiter='\t' --with-nth=2.. --no-sort --cycle \
    --prompt="move $title > " \
    --header='enter  split right  ·  alt+enter  split down  ·  esc cancels' \
    --expect=alt-enter || true)
  [ -n "$out" ] || exit 0

  key=$(printf '%s\n' "$out" | sed -n 1p)
  dest=$(printf '%s\n' "$out" | sed -n 2p | cut -f1)
  [ -n "$dest" ] || exit 0
  case $key in alt-enter) split=down ;; *) split=right ;; esac

  log "pick chose $dest ($split)"
  printf '%s\t%s\n' "$split" "$dest" >"$SELECTION.tmp" && mv "$SELECTION.tmp" "$SELECTION"
  ;;

open)
  # Read `focused` from the pane list rather than trusting HERDR_ACTIVE_PANE_ID,
  # matching the other scripts here, so this behaves the same from a keybind, a
  # plugin action or a shell in some other pane.
  focused=$(herdr pane list | jq -c 'first(.result.panes[] | select(.focused == true))')
  [ -n "$focused" ] || { log "open: nothing focused"; exit 0; }
  pane=$(printf '%s' "$focused" | jq -r .pane_id)
  title=$(printf '%s' "$focused" | jq -r '.terminal_title_stripped // .terminal_title // .pane_id')
  printf '%s\t%s\t%s\t%s\n' \
    "$pane" \
    "$(printf '%s' "$focused" | jq -r .tab_id)" \
    "$(printf '%s' "$focused" | jq -r .workspace_id)" \
    "$title" >"$SOURCE_FILE"

  : >"$SELECTION"
  herdr plugin pane open --plugin "$PLUGIN" --entrypoint picker >/dev/null || {
    log "open: plugin pane open failed (another modal up?)"
    exit 0
  }

  i=0
  while [ "$i" -lt 600 ]; do
    [ -s "$SELECTION" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$SELECTION" ] || { log "open: no choice within 60s"; exit 0; }

  choice=$(cat "$SELECTION")
  : >"$SELECTION"
  split=$(printf '%s' "$choice" | cut -f1)
  dest=$(printf '%s' "$choice" | cut -f2)

  case $dest in
  tab:*) result=$(herdr pane move "$pane" --tab "${dest#tab:}" --split "$split" --focus) ;;
  newtab:*) result=$(herdr pane move "$pane" --new-tab --workspace "${dest#newtab:}" --focus) ;;
  newspace:*) result=$(herdr pane move "$pane" --new-workspace --focus) ;;
  *) log "open: unknown destination $dest"; exit 0 ;;
  esac

  changed=$(printf '%s' "$result" | jq -r '.result.move_result.changed // false')
  if [ "$changed" != true ]; then
    reason=$(printf '%s' "$result" | jq -r '.result.move_result.reason // "refused"')
    log "open: move refused ($reason) $pane -> $dest"
    toast "Pane not moved" "$reason"
    exit 0
  fi

  moved=$(printf '%s' "$result" | jq -r '.result.move_result.pane.pane_id')
  log "open: moved $pane -> $dest as $moved ($split)"
  focus_pane "$moved"
  ;;

*)
  die "unknown command: $cmd"
  ;;
esac
