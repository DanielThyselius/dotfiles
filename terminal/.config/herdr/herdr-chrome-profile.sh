#!/bin/sh
# Open a clicked http(s) link in the Chrome profile that belongs to the herdr
# space it was clicked in.
#
#   herdr-chrome-profile.sh route <url>   the link handler: map, or ask
#   herdr-chrome-profile.sh pick          the picker itself, run inside the popup
#
# Callers: the chrome-profile-links plugin (ctrl+click in herdr) and foot's
# URL mode ([url] launch in foot.ini, alt+o). Links from anywhere else still go
# through xdg-open and the system default browser.
#
# The map is by space LABEL, not workspace id: ids (w4, wA...) are handed out
# by herdr, labels are what you named the space. A space missing from the map
# gets a profile picker instead of a guess.
#
# The picker is a plugin popup (see pane-mover), and the URL reaches it through
# a state file because a popup gets no arguments from whoever opened it. Unlike
# the pane mover, nothing has to happen after the popup closes, so the popup
# launches Chrome itself -- setsid'd, so a cold-started Chrome survives the
# popup's death.
set -eu

PLUGIN=chrome-profile-links
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr"
URL_FILE="$STATE_DIR/chrome-profile.url"
LOG="$STATE_DIR/chrome-profile.log"
LOCAL_STATE="$HOME/.config/google-chrome/Local State"

mkdir -p "$STATE_DIR"

log() {
  printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || return 0
  if [ "$(wc -l <"$LOG" 2>/dev/null || echo 0)" -gt 200 ]; then
    tail -n 100 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
}

# Space label -> Chrome profile directory (the folder name under
# ~/.config/google-chrome, not the display name). Anything not listed here
# opens the picker.
profile_for() { # profile_for <label>
  case $1 in
  grantigo) echo "Profile 1" ;;         # grantigo.com
  ramudden) echo "Profile 2" ;;         # Ramudden
  demelzas-boktips) echo "Profile 3" ;; # Daniel (gmail)
  myarchy | mindful-stack-website | lorekeeper | smarticipate | m3 | system25 | mpd)
    echo "Default" ;;                   # mindfulstack.se
  esac
}

open_in() { # open_in <profile_dir> <url>
  log "open [$1] $2"
  setsid -f uwsm-app -- google-chrome-stable --profile-directory="$1" "$2" \
    >/dev/null 2>&1
}

cmd=${1:-}
case $cmd in
route)
  url=${2:-}
  [ -n "$url" ] || exit 0
  # foot's URL mode (alt+o) launches through here too, for every kind of URL
  # it finds. Only web links are ours; the rest keep their xdg-open handler.
  case $url in
  http://* | https://*) ;;
  *) exec xdg-open "$url" ;;
  esac
  # herdr sets HERDR_WORKSPACE_ID for a plugin action. From foot there is no
  # herdr context at all, so take the space herdr has focused -- the one on
  # screen, since the URL labels were drawn over it.
  ws=${HERDR_WORKSPACE_ID:-$(herdr workspace list 2>/dev/null | jq -r \
    'first(.result.workspaces[] | select(.focused) | .workspace_id) // empty' || true)}
  label=
  [ -n "$ws" ] && label=$(herdr workspace list | jq -r --arg w "$ws" \
    'first(.result.workspaces[] | select(.workspace_id == $w) | .label) // empty')
  profile=$(profile_for "$label")
  if [ -n "$profile" ]; then
    open_in "$profile" "$url"
    exit 0
  fi
  log "route: no profile for space '${label:-?}' ($ws), asking"
  printf '%s\n' "$url" >"$URL_FILE"
  herdr plugin pane open --plugin "$PLUGIN" --entrypoint picker >/dev/null || {
    log "route: popup refused (another modal up?), opening Default"
    open_in Default "$url"
  }
  ;;

pick)
  url=$(cat "$URL_FILE" 2>/dev/null || true)
  : >"$URL_FILE"
  [ -n "$url" ] || exit 0
  # Rows come from Chrome's own profile list, so a new profile shows up here
  # without touching this script. Field 1 (the directory) stays hidden.
  choice=$(jq -r '.profile.info_cache | to_entries | sort_by(.key)[]
      | [.key, .value.name + (if (.value.user_name // "") != "" then "  ·  " + .value.user_name else "" end)]
      | @tsv' "$LOCAL_STATE" |
    fzf --delimiter='\t' --with-nth=2.. --no-sort --cycle \
      --prompt='chrome profile > ' --header="$url" || true)
  [ -n "$choice" ] || exit 0
  open_in "$(printf '%s' "$choice" | cut -f1)" "$url"
  ;;

*)
  echo "usage: $0 {route <url>|pick}" >&2
  exit 2
  ;;
esac
