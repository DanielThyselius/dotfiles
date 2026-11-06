#!/bin/sh
# Open a clicked http(s) link in the Chrome profile that belongs to the herdr
# space it was clicked in.
#
#   herdr-chrome-profile.sh route <url>   the link handler: map, or ask
#   herdr-chrome-profile.sh pick          the picker itself, run inside the popup
#   herdr-chrome-profile.sh pick-toggle   flip the picker's "remember" line
#   herdr-chrome-profile.sh claude-guard  Claude Code PreToolUse hook for the
#                                         claude-in-chrome tools (see below)
#
# Callers: the chrome-profile-links plugin (ctrl+click in herdr) and foot's
# URL mode ([url] launch in foot.ini, alt+o). Links from anywhere else still go
# through xdg-open and the system default browser.
#
# The map is by space LABEL, not workspace id: ids (w4, wA...) are handed out
# by herdr, labels are what you named the space. A space missing from the map
# gets a profile picker instead of a guess. Labels are matched the same on
# every machine, so pingu's "reeve" uses the same map as a local "reeve".
#
# Two maps: the one in profile_for below, and REMEMBERED, written by the
# pickers' "remember for this space" choice. REMEMBERED wins, so remembering
# also re-maps a space listed here. To forget, delete the space's line.
#
# ctrl+alt+o is alt+o that always asks, mapped space or not: a Hyprland bind
# (bindings.lua) drops PICK_FLAG and sends alt+o, the same trick as alt+e.
#
# The picker is a plugin popup (see pane-mover), and the URL reaches it through
# a state file because a popup gets no arguments from whoever opened it. Unlike
# the pane mover, nothing has to happen after the popup closes, so the popup
# launches Chrome itself -- through systemd-run (see open_in), so a cold-started
# Chrome survives the popup's death.
set -eu

PLUGIN=chrome-profile-links
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr"
URL_FILE="$STATE_DIR/chrome-profile.url"
LOG="$STATE_DIR/chrome-profile.log"
LOCAL_STATE="$HOME/.config/google-chrome/Local State"
REVEAL_FLAG="${XDG_RUNTIME_DIR:-/tmp}/foot-url-reveal"
PICK_FLAG="${XDG_RUNTIME_DIR:-/tmp}/foot-url-pick"
REMEMBERED="$STATE_DIR/chrome-profile.map" # <label>\t<profile dir>
REMEMBER_ON="$STATE_DIR/chrome-profile.remember"

mkdir -p "$STATE_DIR"

log() {
  printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || return 0
  if [ "$(wc -l <"$LOG" 2>/dev/null || echo 0)" -gt 200 ]; then
    tail -n 100 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
}

# Space label -> Chrome profile directory (the folder name under
# ~/.config/google-chrome, not the display name). Anything not listed here,
# or remembered, opens the picker.
profile_for() { # profile_for <label>
  [ -n "$1" ] || return 0
  r=$(awk -F'\t' -v l="$1" '$1 == l { d = $2 } END { print d }' "$REMEMBERED" 2>/dev/null || true)
  if [ -n "$r" ]; then
    echo "$r"
    return 0
  fi
  case $1 in
  grantigo) echo "Profile 1" ;;         # grantigo.com
  ramudden) echo "Profile 2" ;;         # Ramudden
  demelzas-boktips) echo "Profile 3" ;; # Daniel (gmail)
  myarchy | mindful-stack-website | lorekeeper | smarticipate | m3 | system25 | mpd)
    echo "Default" ;;                   # mindfulstack.se
  esac
}

# Chrome goes into a systemd service unit of its own, as omarchy-launch-browser
# does. herdr (0.9) kills a popup's processes the moment it closes, before a
# `setsid -f` child has detached, so detaching from inside the pane loses
# Chrome; systemd-run instead returns only once systemd has started the unit,
# outside the pane's process tree.
open_in() { # open_in <profile_dir> <url>
  log "open [$1] $2"
  systemd-run --user --quiet --collect --unit="herdr-chrome-$(date +%s%N)" \
    --property=StandardOutput=null --property=StandardError=null \
    uwsm-app -- google-chrome-stable --profile-directory="$1" "$2" ||
    log "open: systemd-run failed ($?)"
}

# Chrome's own profile list as "<dir>\t<name  ·  email>", so a new profile
# shows up in the pickers without touching this script.
profile_rows() {
  jq -r '.profile.info_cache | to_entries | sort_by(.key)[]
      | [.key, .value.name + (if (.value.user_name // "") != "" then "  ·  " + .value.user_name else "" end)]
      | @tsv' "$LOCAL_STATE"
}

remember() { # remember <label> <profile dir>
  [ -n "$1" ] || return 0
  { awk -F'\t' -v l="$1" '$1 != l' "$REMEMBERED" 2>/dev/null || true
    printf '%s\t%s\n' "$1" "$2"; } >"$REMEMBERED.tmp" &&
    mv "$REMEMBERED.tmp" "$REMEMBERED"
  log "remember [$2] for space '$1'"
}

# The desktop picker, for when the herdr popup cannot be shown where you are
# looking. A row with a subtext comes back as "<label>\t<subtext>", so the
# directory rides along as the subtext. The menu has no modifier keys, so
# "remember" is a second set of rows, their subtext ending in $rem.
desktop_pick() { # desktop_pick <url> <label>
  rem=" · always for $2"
  choice=$(profile_rows | awk -F'\t' -v rem="$rem" -v l="$2" '
      { printf "\t%s\t%s\n", $2, $1; rows[NR] = $0 }
      END { if (l != "") for (i = 1; i <= NR; i++) {
        split(rows[i], f, "\t"); printf "\t%s\t%s%s\n", f[2], f[1], rem } }' |
    omarchy-menu-select "Chrome profile" -- --width 520 2>/dev/null | cut -f2 || true)
  [ -n "$choice" ] || return 0
  dir=${choice%"$rem"}
  [ "$dir" != "$choice" ] && remember "$2" "$dir"
  open_in "$dir" "$1"
}

# The herdr picker's header: the URL, then the remember switch. Clicking the
# switch line, or alt+r, flips it (pick-toggle); fzf redraws the header from
# what pick-toggle prints.
pick_header() { # pick_header <url> <label>
  if [ -z "$2" ]; then
    printf '%s' "$1"
    return
  fi
  if [ -s "$REMEMBER_ON" ]; then box='[x]'; else box='[ ]'; fi
  printf '%s\n%s remember for %s   (click or alt+r)' "$1" "$box" "$2"
}

# herdr against the local server ("") or a saved machine's SSH target.
#
# Not `herdr --machine`: that sets up its own SSH session per call, 5-8s each,
# and a lookup takes several. Plain ssh to the remote herdr, over a master
# connection this script keeps for 8h, is ~3s cold and ~0.4s warm for a whole
# lookup. The ControlPath is our own, so neither ~/.ssh/config nor herdr's
# connections share it. Arguments must be shell-safe words (ids, flags).
SSH_CTL="${XDG_RUNTIME_DIR:-/tmp}/herdr-chrome-ssh-%C"
rssh() { # rssh <target> <ssh args...>
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o ControlMaster=auto \
    -o ControlPath="$SSH_CTL" -o ControlPersist=8h "$@" </dev/null
}
hd() { # hd <target> <args...>
  m=$1
  shift
  if [ -n "$m" ]; then rssh "$m" "herdr $*"; else herdr "$@"; fi
}

# Open the masters in the background, so the first alt+o on a machine after
# the 8h lapse is not the one that pays for the connection.
warm_machines() {
  for m in $(herdr machine list --json 2>/dev/null |
    jq -r '.[] | select(.enabled) | .target' || true); do
    rssh "$m" -O check 2>/dev/null ||
      (rssh "$m" -fN >/dev/null 2>&1 &)
  done
}

# Is <url> on screen in the tab this server has focused? The ANSI read keeps
# OSC 8 targets, so a link whose text is not its URL still matches.
shows_url() { # shows_url <machine> <snapshot> <url>
  printf '%s' "$2" | jq -r '.result.snapshot as $s
    | $s.panes[] | select(.tab_id == $s.focused_tab_id)
    | [(.pane_id == $s.focused_pane_id | not), .pane_id] | @tsv' |
    sort | cut -f2 | {
    # focused pane first; the loop runs in a subshell, hence exit, not return
    while IFS= read -r p; do
      hd "$1" pane read "$p" --source visible --format ansi 2>/dev/null |
        grep -qF -- "$3" && exit 0
    done
    exit 1
  }
}

cmd=${1:-}
case $cmd in
route)
  url=${2:-}
  [ -n "$url" ] || exit 0
  # alt+e is foot's URL mode with a twist: a Hyprland bind (bindings.lua) drops
  # a timestamp in REVEAL_FLAG and sends alt+o, and the next file link launched
  # within 30s is shown in Nautilus instead of opened. foot has only one launch
  # command, so this is the one way to give it a second one. foot hands OSC 8
  # file links over as bare paths, not file:// URLs.
  if [ -f "$REVEAL_FLAG" ]; then
    ts=$(cat "$REVEAL_FLAG" 2>/dev/null || echo 0)
    rm -f "$REVEAL_FLAG"
    case $url in
    file://* | /*) [ $(($(date +%s) - ${ts:-0})) -le 30 ] && exec open-in-files "$url" ;;
    esac
  fi
  # foot's URL mode (alt+o) launches through here too, for every kind of URL
  # it finds. Only web links are ours; the rest keep their xdg-open handler.
  case $url in
  http://* | https://*) ;;
  *) exec xdg-open "$url" ;;
  esac
  # ctrl+alt+o: ask even in a mapped space (same 30s window as alt+e).
  force=
  if [ -f "$PICK_FLAG" ]; then
    ts=$(cat "$PICK_FLAG" 2>/dev/null || echo 0)
    rm -f "$PICK_FLAG"
    [ $(($(date +%s) - ${ts:-0})) -le 30 ] && force=1
  fi
  # herdr sets HERDR_WORKSPACE_ID for a plugin action. From foot there is no
  # herdr context at all, so take the space on screen, since the URL labels
  # were drawn over it. Which one that is, herdr does not say: the client can
  # show a saved machine's spaces (pingu) next to the local ones, and every
  # server keeps its own focus, so the local server still reports its last
  # space while you look at pingu's. The server whose focused tab shows the
  # URL is the one on screen; failing that, the local focus as before.
  machine=
  ws=${HERDR_WORKSPACE_ID:-}
  snap=
  if [ -z "$ws" ]; then
    for m in "" $(herdr machine list --json 2>/dev/null |
      jq -r '.[] | select(.enabled) | .target' || true); do
      s=$(hd "$m" api snapshot 2>/dev/null) || continue
      [ -z "$m" ] && snap=$s # the fallback if no server shows the URL
      if shows_url "$m" "$s" "$url"; then
        machine=$m snap=$s
        break
      fi
    done
    ws=$(printf '%s' "$snap" | jq -r '.result.snapshot.focused_workspace_id // empty' 2>/dev/null || true)
  else
    warm_machines # a local ctrl+click readies the next alt+o on a machine
    snap=$(herdr api snapshot 2>/dev/null || true)
  fi
  label=
  [ -n "$ws" ] && label=$(printf '%s' "$snap" | jq -r --arg w "$ws" \
    'first(.result.snapshot.workspaces[] | select(.workspace_id == $w) | .label) // empty')
  profile=$(profile_for "$label")
  if [ -n "$profile" ] && [ -z "$force" ]; then
    open_in "$profile" "$url"
    exit 0
  fi
  if [ -n "$force" ]; then
    log "route: picker asked for in space '${label:-?}' (${machine:+$machine:}$ws)"
  else
    log "route: no profile for space '${label:-?}' (${machine:+$machine:}$ws), asking"
  fi
  # The popup is a local plugin pane, drawn in the local server's focused
  # space: right for a local space, invisible while you look at a machine.
  if [ -n "$machine" ]; then
    desktop_pick "$url" "$label"
    exit 0
  fi
  printf '%s\n%s\n' "$url" "$label" >"$URL_FILE"
  herdr plugin pane open --plugin "$PLUGIN" --entrypoint picker >/dev/null || {
    log "route: popup refused (another modal up?), asking on the desktop"
    : >"$URL_FILE"
    desktop_pick "$url" "$label"
  }
  ;;

pick)
  url=$(sed -n 1p "$URL_FILE" 2>/dev/null || true)
  label=$(sed -n 2p "$URL_FILE" 2>/dev/null || true)
  : >"$URL_FILE"
  [ -n "$url" ] || exit 0
  : >"$REMEMBER_ON"
  # pick-toggle runs in fzf's child shell and needs these to redraw the header.
  PICK_URL=$url PICK_LABEL=$label
  export PICK_URL PICK_LABEL
  self="'$(printf '%s' "$0" | sed "s/'/'\\\\''/g")'"
  # Field 1 (the directory) stays hidden. One click opens a row: fzf's own
  # left-click only moves the cursor and wants a double-click to accept.
  choice=$(profile_rows |
    fzf --delimiter='\t' --with-nth=2.. --no-sort --cycle \
      --prompt='chrome profile > ' --header="$(pick_header "$url" "$label")" \
      --bind 'left-click:accept' \
      --bind "click-header:transform-header($self pick-toggle \$FZF_CLICK_HEADER_LINE)" \
      --bind "alt-r:transform-header($self pick-toggle 2)" || true)
  [ -n "$choice" ] || exit 0
  dir=$(printf '%s' "$choice" | cut -f1)
  [ -s "$REMEMBER_ON" ] && remember "$label" "$dir"
  : >"$REMEMBER_ON"
  open_in "$dir" "$url"
  ;;

pick-toggle)
  # Header line 2 is the remember switch; a click on the URL line changes
  # nothing, but fzf still wants the header back.
  if [ "${2:-}" = 2 ] && [ -n "${PICK_LABEL:-}" ]; then
    if [ -s "$REMEMBER_ON" ]; then : >"$REMEMBER_ON"; else echo 1 >"$REMEMBER_ON"; fi
  fi
  pick_header "${PICK_URL:-}" "${PICK_LABEL:-}"
  ;;

claude-guard)
  # Pre+PostToolUse hook (matcher ^mcp__claude-in-chrome__) holding a Claude session
  # to the Chrome profile of the space it runs in -- the same map as links.
  #
  # Every profile with the extension is a separate "browser" to Claude, known
  # only by a deviceId the extension keeps in its own storage
  # (bridgeDeviceId). Unselected, a session drives whichever browser was
  # picked LAST by any session, so a grantigo agent could end up in the
  # mindfulstack profile. The guard denies browser tools until the session
  # has run select_browser with this space's deviceId; the deny reason tells
  # Claude which id that is. Picking another browser asks the user.
  #
  # The space is looked up live (pane whose agent session is this one), so a
  # pane moved to another space switches profile on its next browser call.
  # Outside herdr, or in an unmapped space, the guard stays out of the way.
  [ "${HERDR_ENV:-}" = 1 ] || exit 0
  input=$(cat)
  sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
  tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
  tool=${tool#mcp__claude-in-chrome__}
  [ "$tool" = list_connected_browsers ] && exit 0

  decide() { # decide allow|deny|ask <reason>
    jq -n --arg d "$1" --arg r "$2" '{hookSpecificOutput: {hookEventName:
      "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
    exit 0
  }

  ws=$(herdr pane list 2>/dev/null | jq -r --arg s "$sid" \
    'first(.result.panes[] | select(.agent_session.value == $s) | .workspace_id) // empty' || true)
  ws=${ws:-${HERDR_WORKSPACE_ID:-}}
  label=$(herdr workspace list 2>/dev/null | jq -r --arg w "$ws" \
    'first(.result.workspaces[] | select(.workspace_id == $w) | .label) // empty' || true)
  profile=$(profile_for "$label")
  [ -n "$profile" ] || exit 0
  pname=$(jq -r --arg p "$profile" '.profile.info_cache[$p].name // $p' "$LOCAL_STATE")

  # Newest value wins: the .log is LevelDB's write-ahead log, newer than any
  # .ldb table, so read tables first and the log last.
  store="$HOME/.config/google-chrome/$profile/Local Extension Settings/fcoeoabgfenejglbffodgkkbkcdhcgfn"
  device=$(ls -tr "$store"/*.ldb "$store"/*.log 2>/dev/null | while IFS= read -r f; do
    strings -n 4 "$f" | grep -A1 bridgeDeviceId
  done | grep -oE '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' | tail -n 1 || true)
  [ -n "$device" ] || decide deny "This herdr space ($label) maps to the Chrome \
profile \"$pname\" ($profile), but the Claude extension has never connected \
there. Ask the user to install or enable the Claude extension in that profile; \
do not use another profile."

  # The selection is recorded by the PostToolUse half, i.e. only once
  # select_browser really ran. It is stored with the space it was made in: an
  # override the user approved holds for that space, and a move to another
  # space forces a fresh select.
  sel="$STATE_DIR/claude-chrome/$sid"
  event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty')
  if [ "$event" = PostToolUse ]; then
    case $tool in
    select_browser)
      mkdir -p "${sel%/*}"
      printf '%s\n' "$label" >"$sel"
      ;;
    switch_browser) printf '%s\n' "$label" >"$sel" ;; # the user picked in Chrome
    esac
    exit 0
  fi
  case $tool in
  select_browser)
    want=$(printf '%s' "$input" | jq -r '.tool_input.deviceId // empty')
    [ "$want" = "$device" ] && exit 0
    decide ask "Space $label uses Chrome profile \"$pname\" (deviceId $device), \
not $want."
    ;;
  switch_browser)
    decide ask "Space $label uses Chrome profile \"$pname\"; switch_browser lets \
any profile connect."
    ;;
  esac
  [ "$(cat "$sel" 2>/dev/null)" = "$label" ] && exit 0
  log "claude-guard: session $sid in '$label' not on $profile yet, denying $tool"
  decide deny "This herdr space ($label) uses the Chrome profile \"$pname\". \
Call mcp__claude-in-chrome__select_browser with deviceId $device first, then \
retry. Do not ask the user which browser to use. If that device is not \
connected, ask the user to open a Chrome window in the \"$pname\" profile."
  ;;

*)
  echo "usage: $0 {route <url>|pick|pick-toggle <line>|claude-guard}" >&2
  exit 2
  ;;
esac
