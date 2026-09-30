#!/bin/sh
# Rank the agents that are waiting on you, and jump to the top of that ranking.
#
#   herdr-agent-priority.sh up [pane_id]      raise one step, stops at 5
#   herdr-agent-priority.sh down [pane_id]    lower one step, stops at 1
#   herdr-agent-priority.sh set <1-5> [pane_id]
#   herdr-agent-priority.sh clear [pane_id]
#   herdr-agent-priority.sh clear-many <file>  clear the ranks of the live
#                                               panes named in <file>, one per
#                                               line, tab-delimited field 1 —
#                                               a bare id or a full rows() row
#   herdr-agent-priority.sh snooze [pane_id]   step the snooze: 5m, 30m, 2h, 4h, off
#   herdr-agent-priority.sh goto              focus the next highest-priority waiting agent
#   herdr-agent-priority.sh open              open the picker and act on its choice
#   herdr-agent-priority.sh pick              the picker itself, run inside the popup
#   herdr-agent-priority.sh rows              the picker's rows, also fzf's reload source
#   herdr-agent-priority.sh view              re-apply the priority sort to the sidebar
#   herdr-agent-priority.sh stamp             re-apply priorities and the sort (startup hook)
#   herdr-agent-priority.sh list              show the queue goto walks, in order
#   herdr-agent-priority.sh ticker            refresh snooze labels once a minute (started by snooze/stamp)
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
# TWO TOKENS, ONE VISIBLE. $pri carries the label and is only set when you have
# actually ranked something, so thirty untriaged rows stay clean. $prisort is
# stamped on EVERY agent, defaulting to 3, and is never referenced by the
# sidebar template, so it is invisible. It exists because the sidebar sort is a
# string sort over a token: with $pri alone the unranked rows have no value at
# all and sink to the bottom, which would put a deliberate "1, I am not doing
# this" above an untriaged agent. Sorting on a token that is always present puts
# unset exactly where it belongs, in the middle.
#
# THE SORT ITSELF is herdr's declarative agent view (agent.view.set), which
# accepts `{"field": {"token": "prisort"}}` as a sort key. Setting a view with a
# label makes the client take its row order from the server's agent_order and
# ignore ui.agent_panel_sort entirely, so no fork is needed to order the panel.
# There is no CLI verb for it, hence the socket call below.
#
# LOOP HAZARD, same as herdr-number-sidebar.sh: report-metadata fires
# pane.updated and *.metadata_updated. The plugin must never hook those events,
# and it does not — startup only.
set -eu

SOURCE=agent-priority
DEFAULT=3
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr"
STORE="$STATE_DIR/agent-priority"
SNOOZE="$STATE_DIR/agent-snooze"
SELECTION="$STATE_DIR/agent-priority.selection"
LOG="$STATE_DIR/agent-priority.log"
NOTIFY_ID="$STATE_DIR/agent-priority.notify-id"
LOCK="$STATE_DIR/agent-priority.lock"
SNZ_SOURCE=agent-snooze
TICKER_LOCK="$STATE_DIR/agent-snooze.ticker.lock"

mkdir -p "$STATE_DIR"
[ -f "$STORE" ] || : >>"$STORE"
[ -f "$SNOOZE" ] || : >>"$SNOOZE"

die() { echo "$*" >&2; exit 2; }

# Test seam. Widens the gap between reading a store and writing it back, so the
# concurrency tests can tell a locked store from an unlocked one — without it
# the window is a few milliseconds and the race only shows up by luck. Unset in
# normal use, where it costs one test.
crit_delay() { [ -z "${AGENT_PRIORITY_CRIT_DELAY:-}" ] || sleep "$AGENT_PRIORITY_CRIT_DELAY"; }

# Every invocation leaves a line. Keybind commands are spawned by the server
# with no terminal attached, so a failure here is otherwise completely silent —
# which is exactly how a missing symlink went unnoticed for a day.
log() {
  printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || return 0
  if [ "$(wc -l <"$LOG" 2>/dev/null || echo 0)" -gt 200 ]; then
    tail -n 100 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
}

# Feedback where the eyes already are. Changing a rank otherwise only shows up
# in the sidebar, which is the thing you are trying not to have to read.
#
# NOT `herdr notification show`. That reports {"shown": true} and then does
# nothing here, for two compounding reasons: notification.show is not in the
# server's client-shell method allowlist, and herdr's own terminal notification
# backend only recognises ghostty, iterm, kitty and wezterm (see
# src/terminal_notify.rs detect_backend), so under foot it returns false and
# drops the message. notify-send talks to whatever owns
# org.freedesktop.Notifications, which under Omarchy 4 is quickshell.
#
# Replacing rather than stacking is done with the spec's own replaces_id, not
# with the x-canonical-private-synchronous hint. That hint is a notify-osd
# extension which mako honours and quickshell ignores, so under Omarchy 4 it
# stacked a fresh toast per keypress. --print-id hands back the id the daemon
# assigned, --replace-id offers it back next time, and the daemon returning the
# same id is the confirmation that it replaced in place. Replacing an id that
# has already expired just makes a new one, which is the behaviour we want.
toast() { # toast <title> <body>
  command -v notify-send >/dev/null 2>&1 || return 0
  prev=$(cat "$NOTIFY_ID" 2>/dev/null || true)
  case $prev in '' | *[!0-9]*) prev=0 ;; esac
  id=$(notify-send --app-name=herdr --expire-time=2000 --print-id \
    --replace-id="$prev" -- "$1" "$2" 2>/dev/null) || return 0
  case $id in '' | *[!0-9]*) ;; *) printf '%s\n' "$id" >"$NOTIFY_ID" ;; esac
}

# The key a subcommand of this script is bound to, as you would actually press
# it, or nothing if it is unbound. Read from config.toml rather than hardcoded
# because the hint in a toast is only useful while it is true, and the bindings
# have moved before (the picker went from alt+p to prefix+p). `prefix+` is
# expanded to the real prefix, since "prefix" is config vocabulary, not a key.
keybind_for() { # keybind_for <subcommand>
  python3 - "$1" "${HERDR_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}" \
    <<'PYKEY' 2>/dev/null || true
import re, sys, tomllib
sub, path = sys.argv[1], sys.argv[2]
with open(path, "rb") as f:
    keys = tomllib.load(f).get("keys", {})
# A word boundary isn't enough: "open" is also a boundary inside "open-foo",
# since - is not a word character. Require what actually follows a shell
# token instead: whitespace, a closing quote, or end of string.
quote_chars = '"' + "'"
pat = re.compile(r"herdr-agent-priority\.sh\s+" + re.escape(sub) +
                  r"(?=\s|[" + quote_chars + r"]|$)")
for c in keys.get("command", []):
    if pat.search(c.get("command", "")):
        k = c.get("key", "")
        if k.startswith("prefix+") and keys.get("prefix"):
            k = keys["prefix"] + " " + k[len("prefix+"):]
        print(k)
        break
PYKEY
}

pane_title() { # pane_title <pane_id>
  herdr agent list | jq -r --arg p "$1" \
    'first(.result.agents[] | select(.pane_id == $p)
      | (.terminal_title_stripped // .terminal_title // .pane_id)) // empty'
}

notify() { # notify <pane_id> <priority|"">
  title=$(pane_title "$1")
  [ -n "$title" ] || title="$1"
  if [ -n "$2" ]; then
    toast "Priority $2" "$title"
  else
    toast "Priority cleared" "$title"
  fi
}

focused_pane() {
  herdr agent list | jq -r 'first(.result.agents[] | select(.focused) | .pane_id) // empty'
}

# Resolve the pane a command applies to: explicit argument, else the focused
# one. An explicit id is checked against the live agent list and resolves to
# nothing if it is not there, so a stale or mistyped id can never put a line in
# a store. Read from the agent list rather than $HERDR_PANE_ID so the same
# script works from a keybind, a plugin action and a shell inside some other
# pane.
target_pane() {
  if [ -n "${1:-}" ]; then
    list=$(herdr agent list) || { log "target_pane: agent list failed"; return 0; }
    p=$(printf '%s\n' "$list" | jq -r --arg p "$1" \
      'first(.result.agents[] | select(.pane_id == $p) | .pane_id) // empty')
    [ -n "$p" ] || log "target_pane: not a live agent: $1"
    printf '%s\n' "$p"
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
    herdr pane report-metadata "$1" --source "$SOURCE" \
      --token "pri=P$2" --token "prisort=$2" >/dev/null
  else
    herdr pane report-metadata "$1" --source "$SOURCE" \
      --clear-token pri --token "prisort=$DEFAULT" >/dev/null
  fi
}

# SNOOZE. "Not right now" for a pane whose next step is waiting on someone
# else — another agent's review, a human, an email. A snoozed pane drops out of
# the alt+g queue until its time is up and then simply counts again: nothing
# runs at expiry, the queue just stops excluding it. Kept apart from the rank
# store because importance and timing are different facts.
#
# Lines are pane<TAB>wake_epoch<TAB>step, step in minutes. The step is stored
# rather than derived from the time left, because a half-used 30m would
# otherwise look like a fresh 15m and the next press would pick the wrong rung.

# Active snoozes only. A line is dropped unless it has exactly 3 fields, the
# wake is numeric and no more than 4h (the longest rung) from now — further out
# than that is not a real snooze, whatever put it there — the step is one of
# the four rungs, and the wake is still in the future. Every rewrite drops
# anything that fails these checks.
snoozes_active() {
  awk -F'\t' -v now="$(date +%s)" \
    'NF == 3 && $2 ~ /^[0-9]+$/ && $3 ~ /^(5|30|120|240)$/ \
     && $2 + 0 > now + 0 && $2 + 0 <= now + 240 * 60' "$SNOOZE"
}

snooze_label() { # snooze_label <minutes>: 5m, 30m, 2h, 4h
  if [ "$1" -ge 60 ]; then echo "$(($1 / 60))h"; else echo "${1}m"; fi
}

# THE SIDEBAR LABEL. A snoozed row shows its time left as the $snz token,
# "zz 24m". It is a separate metadata source from the ranks on purpose: the
# label carries a TTL, and a TTL on the agent-priority source would expire
# pri and prisort with it. The TTL is the safety net — never longer than 90 s
# and never past the wake — so a label nobody refreshes disappears instead of
# showing a wrong time. Every write goes through the store lock, like the rank
# stamp, and a failed write is logged, never fatal: the store is the truth, the
# label a projection of it.
snooze_left() { # snooze_left <seconds>: minutes rounded up — 5m, 59m, 1h, 1h5m, 2h10m, 4h
  m=$(( ($1 + 59) / 60 ))
  if [ "$m" -lt 60 ]; then
    echo "${m}m"
  elif [ $((m % 60)) -eq 0 ]; then
    echo "$((m / 60))h"
  else
    echo "$((m / 60))h$((m % 60))m"
  fi
}

snz_clear() { # snz_clear <pane_id> <caller>
  herdr pane report-metadata "$1" --source "$SNZ_SOURCE" --clear-token snz >/dev/null ||
    log "$2: snz clear failed for $1"
}

# The time left is computed here, immediately before the report, so a label
# can never be written with a TTL that outlives its wake. A wake already past
# means the snooze is over: clear instead.
snz_report() { # snz_report <pane_id> <wake_epoch> <caller>
  left=$(( $2 - $(date +%s) ))
  if [ "$left" -le 0 ]; then
    snz_clear "$1" "$3"
    return 0
  fi
  ttl=$(( left * 1000 ))
  [ "$ttl" -le 90000 ] || ttl=90000
  herdr pane report-metadata "$1" --source "$SNZ_SOURCE" \
    --token "snz=zz $(snooze_left "$left")" --ttl-ms "$ttl" >/dev/null ||
    log "$3: snz report failed for $1"
}

# Start the ticker, detached, unless one already runs (it checks that itself
# and exits at once). Called only AFTER a `locked` section has returned, never
# inside one: a child started in there inherits fd 9 and holds the store lock
# for its whole life (see `locked`). fd 9 is closed explicitly anyway.
#
# `setsid -f` "Always create[s] a new process" (setsid(1)): it forks, the child
# starts a new session and becomes the ticker, and setsid itself returns at
# once — so nothing here is a background job. stdio goes to /dev/null because
# a plugin command's stdout/stderr are pipes herdr reads until EOF: a ticker
# holding them would leave the command that started it "running" in herdr's
# plugin log, and herdr caps those at 32.
ensure_ticker() {
  setsid -f "$SELF" ticker 9>&- </dev/null >/dev/null 2>&1 ||
    log "ensure_ticker: could not start the ticker"
}

# THE TICKER. One background process refreshes every snooze label once a
# minute while anything is snoozed, and exits when nothing is. Nothing tracks
# PIDs: it holds `flock -n` on $TICKER_LOCK (fd 8) for its lifetime, and a
# start that finds that taken exits at once.
#
# EXIT/START HANDOFF. The race: a ticker decides to exit, a new snooze starts
# a replacement, the replacement finds the singleton still held and leaves,
# then the old ticker exits — and the new snooze has no updater. Closed by
# taking both decisions under the store lock: the ticker releases fd 8 at the
# end of its pass, *inside* the critical section, when it found nothing
# snoozed; `snooze` writes its line inside its own critical section and starts
# a ticker only after releasing the lock. Either the pass ran first (fd 8 is
# already free when the replacement asks) or the snooze did (the pass sees the
# new line and keeps running; the replacement correctly leaves).
ticker_release() { exec 8>&-; ticker_exit=1; }

# Test seam: record, from inside the critical section, whether the singleton
# and the store lock are held right now. A fresh open conflicts with a lock
# this process holds on another descriptor, so `flock -n` on the path answers
# exactly that. Unset in normal use.
tick_probe() {
  [ -n "${AGENT_PRIORITY_TICK_PROBE:-}" ] || return 0
  t=held
  flock -n "$TICKER_LOCK" true 2>/dev/null && t=free
  s=held
  flock -n "$LOCK" true 2>/dev/null && s=free
  printf 'ticker=%s store=%s\n' "$t" "$s" >>"$AGENT_PRIORITY_TICK_PROBE"
}

# Read outside the store lock, once per pass, into $agents (pane<TAB>current
# $snz token). Safe there because this list only decides which panes get a
# report vs a clear, and either write is idempotent: a pane this read missed
# just gets picked up next pass, and a stale token here costs one redundant
# clear next time round, never a wrong result. The decision that actually
# matters — whether to keep the ticker running at all — is NOT taken from
# this: it comes from a fresh read of the snooze store inside the lock (see
# tick_pass), because a snooze that lands between this read and the lock must
# not be missed for a whole minute. Reading the list out here also means a
# hung `herdr agent list` cannot block a `snooze` press waiting on the same
# lock.
#
# Logged only on a state change (failed/empty/ok), never every minute, so a
# real herdr outage shows up once instead of drowning the log for however
# long it lasts, and distinctly from "herdr is up but nothing is attached".
tick_read_agents() {
  agents=''
  tick_state=failed
  if alist=$(herdr agent list); then
    agents=$(printf '%s\n' "$alist" |
      jq -r '.result.agents[] | "\(.pane_id)\t\(.tokens.snz // "")"' 2>/dev/null) || agents=''
    if [ -n "$agents" ]; then tick_state=ok; else tick_state=empty; fi
  fi
  tick_prev=${tick_agents_state:-}
  tick_agents_state=$tick_state
  if [ "$tick_state" != "$tick_prev" ]; then
    case $tick_state in
    failed) log "tick: agent list unavailable, no labels until it recovers" ;;
    empty) log "tick: agent list has no agents, no labels this pass" ;;
    ok) [ -z "$tick_prev" ] || log "tick: agent list back" ;;
    esac
  fi
}

# One pass, run under `tick_locked` so it can never publish a label that a
# `snooze` press has since changed: the press either finished before this
# pass (the fresh store read below sees it) or waits for the pass and
# overwrites it. $agents comes from `tick_read_agents`, read before the lock.
#
# Whether to keep running is decided by the STORE, not the agent list: with
# herdr down the list fails every pass, and a ticker that waited for it would
# never exit. With the store deciding, it stops within 4 h (the longest rung)
# whatever herdr does.
tick_pass() {
  active=$(snoozes_active) || {
    log "tick: snooze read failed, stopping"
    ticker_release
    return 0
  }
  if [ -n "$agents" ]; then
    crit_delay
    printf '%s\n' "$agents" |
      while IFS='	' read -r pane cur; do
        [ -n "$pane" ] || continue
        wake=$(printf '%s\n' "$active" | awk -F'\t' -v p="$pane" '$1 == p { print $2; exit }')
        if [ -n "$wake" ]; then
          snz_report "$pane" "$wake" tick
        elif [ -n "$cur" ]; then
          # Expired, switched off or edited away, but still on screen. Driven
          # by the token because $active has already lost expired lines.
          snz_clear "$pane" tick
        fi
      done
  fi
  [ -n "$active" ] || { log "tick: nothing snoozed, stopping"; ticker_release; }
  tick_probe
}

# The ticker's own acquire, distinct from `locked` above: `locked`'s `exit 1`
# on a timed-out flock is fine for a one-shot keypress process (it just dies,
# leaving a stale sidebar until the next press), but the ticker is long-lived
# — dying here would drop every snooze label for up to 4h, with only a
# generic "lock: timed out after 5s" line to explain it. So a timeout SKIPS
# this pass and loops again instead of exiting: the next pass, a minute away,
# finds the same store either way. Runs in THIS shell (brace group, not
# subshell), exactly like `locked`, so `ticker_release`'s `exec 8>&-` and
# `ticker_exit=1` still take effect on the caller when a pass does complete.
#
# AGENT_PRIORITY_LOCK_WAIT: test seam so the timeout itself is provable
# without an actual 5s wait (0 or 1). Unset in normal use.
tick_locked() {
  {
    flock -w "${AGENT_PRIORITY_LOCK_WAIT:-5}" 9 ||
      { log "tick: store lock busy, skipping this pass"; return 0; }
    tick_pass
  } 9>"$LOCK"
}

snooze_step() { # snooze_step <pane_id>; run under `locked`; sets $step and $wake
  # The store is read exactly once here, into a file rather than a pipe, so a
  # failing read (a corrupt store, a missing file) aborts loudly under set -e
  # instead of a pipeline silently swallowing the first awk's exit status —
  # which piping snoozes_active straight into the write's filter used to do,
  # and could have replaced the whole store with just this pane's line.
  snap=$(mktemp "$SNOOZE.XXXXXX")
  snoozes_active >"$snap"
  cur=$(awk -F'\t' -v p="$1" '$1 == p { print $3; exit }' "$snap")
  case $cur in
  '') step=5 ;;
  5) step=30 ;;
  30) step=120 ;;
  120) step=240 ;;
  *) step='' ;;
  esac
  crit_delay
  wake=''
  tmp=$(mktemp "$SNOOZE.XXXXXX")
  awk -F'\t' -v p="$1" '$1 != p' "$snap" >"$tmp"
  if [ -n "$step" ]; then
    wake=$(($(date +%s) + step * 60))
    printf '%s\t%s\t%s\n' "$1" "$wake" "$step" >>"$tmp"
  fi
  mv "$tmp" "$SNOOZE"
  # Inside the lock, like rank_write's stamp: outside it, two quick presses
  # could store 30m then 2h but label 2h then 30m.
  if [ -n "$step" ]; then
    snz_report "$1" "$wake" snooze
  else
    snz_clear "$1" snooze
  fi
  rm -f "$snap"
}

# Startup cleanup, run under `locked`: drop entries whose pane is gone from
# both stores, drop expired or malformed snoozes so that file cannot grow
# without bound, and re-project the rank store onto metadata tokens (a
# restore wiped them).
#
# GUARDED ON THE LIVE LIST. `herdr pane list` can fail outright (herdr not up
# yet, "server_not_running") or come back with no panes, and this hook fires
# on every pane.agent_detected — far more often than a real restart. Without
# this guard, either case makes `live` empty, which reads as "every pane is
# gone": the rank store and the snooze store would both be wiped, and the
# reconcile below would then clear every visible rank too, all silently
# (exit 0, nothing logged). So both the raw call and the parse are checked
# before anything is touched, and a failure of either returns before either
# store is rewritten and before the reconcile runs — it depends on the same
# live list for the same reason.
#
# The prisort reconcile (every agent needs the hidden sort token or it falls
# off the bottom of the panel) runs in here too, not after `locked prune`
# returns. It reads the store via `stored` and writes metadata via
# `stamp_one`, exactly like the store rewrite above it — outside the lock a
# concurrent `up`/`set`/`clear` could land between this read and its
# stamp_one, and this stale restamp would overwrite that fresher write.
prune() {
  list=$(herdr pane list) || { log "prune: pane list failed, not pruning"; return 0; }
  ids=$(printf '%s\n' "$list" | jq -er '.result.panes[].pane_id') || {
    log "prune: no live panes parsed, not pruning"
    return 0
  }
  live=$(printf '%s\n' "$ids" | sort -u)

  # Pure file rewrite: drop lines for gone panes. Restamping every surviving
  # line unconditionally used to happen here too, but that made every ranked
  # pane cost a report-metadata call on every stamp regardless of whether its
  # token already matched. The reconcile loop below already restamps any live
  # agent whose prisort disagrees with the store (stamp_one writes pri and
  # prisort together), so it alone is enough to keep tokens correct.
  tmp=$(mktemp "$STORE.XXXXXX")
  while IFS='	' read -r pane pri; do
    [ -n "$pane" ] || continue
    if printf '%s\n' "$live" | grep -qx "$pane"; then
      printf '%s\t%s\n' "$pane" "$pri" >>"$tmp"
    fi
  done <"$STORE"
  mv "$tmp" "$STORE"

  # The snoozes are read once into a variable, never piped straight into the
  # write loop below: under `set -e` a failing snoozes_active here must abort
  # this critical section (leaving the snooze store untouched — the rank
  # store above has already been rewritten by this point) rather than have
  # its exit status swallowed by the pipe into `while`.
  active=$(snoozes_active)
  tmp=$(mktemp "$SNOOZE.XXXXXX")
  printf '%s\n' "$active" |
    while IFS='	' read -r pane wake step; do
      [ -n "$pane" ] || continue
      if printf '%s\n' "$live" | grep -qx "$pane"; then
        printf '%s\t%s\t%s\n' "$pane" "$wake" "$step"
      fi
    done >"$tmp"
  mv "$tmp" "$SNOOZE"

  alist=$(herdr agent list) || { log "prune: agent list failed, not reconciling"; return 0; }
  printf '%s\n' "$alist" |
    jq -r '.result.agents[] | "\(.pane_id)\t\(.tokens.prisort // "")"' |
    while IFS="$(printf '\t')" read -r pane cur; do
      [ -n "$pane" ] || continue
      want=$(stored "$pane")
      [ -n "$want" ] || want=$DEFAULT
      [ "$cur" = "$want" ] || stamp_one "$pane" "$(stored "$pane")" ||
        log "prune: stamp failed: $pane"
    done

  # A label can outlive its snooze: a clear failed, or the snooze expired and
  # nothing has ticked since. Clear every live label with no active snooze
  # behind it. Driven by the agent list's tokens, not the store, because
  # $active has already lost expired lines. Active labels are the ticker's.
  printf '%s\n' "$alist" |
    jq -r '.result.agents[] | select((.tokens.snz // "") != "") | .pane_id' |
    while read -r pane; do
      [ -n "$pane" ] || continue
      printf '%s\n' "$active" | cut -f1 | grep -qxF "$pane" || snz_clear "$pane" prune
    done
}

# Tell herdr to order the agent panel by the hidden sort token. Ranked first,
# then whoever is actually asking for something, then the usual space order so
# equal rows keep a stable, familiar arrangement.
set_view() {
  python3 - "$SOURCE" <<'PYVIEW' >/dev/null 2>&1 || true
import json, os, socket, sys
req = {
    "id": "agent-priority:view",
    "method": "agent.view.set",
    "params": {
        "source": sys.argv[1],
        "label": "priority",
        "sort": [
            {"field": {"token": "prisort"}, "order": "desc"},
            {"field": "attention", "order": "desc"},
            {"field": "workspace_order", "order": "asc"},
            {"field": "pane_order", "order": "asc"},
        ],
    },
}
path = os.path.expanduser("~/.config/herdr/herdr.sock")
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect(path)
s.sendall((json.dumps(req) + "\n").encode())
s.recv(65536)
PYVIEW
}

# Every read-modify-write of a store runs under one exclusive lock. Each
# keypress is its own process, and repeated presses are the intended
# interaction, so without it two quick presses both read the old value and one
# step is lost. The brace group runs in THIS shell, so a critical section's
# results (next, step, wake) are visible to the caller afterwards; the lock is
# released when fd 9 closes at the end of the group, or when the process exits.
# The wait is bounded at 5s: a hung `herdr pane report-metadata` inside the
# critical section would otherwise block every later keypress silently, and
# logging the timeout means a run of them shows up instead of just going
# quiet. Dying on that timeout is fine here — this process is one keypress,
# and dying leaves nothing behind but a stale sidebar until the next press.
# The ticker is long-lived, so a timeout there must not exit the process
# (that would drop every label for up to 4h): see `tick_locked`, its own
# variant of this same lock, which skips the pass and loops again instead.
#
# CONTRACT for callers, here and in later tasks: call `locked` as a plain
# command, never in a condition. `if locked ...` or `locked ... ||` disables
# `set -e` *inside* the critical section, so a failing mktemp/awk there falls
# through instead of aborting and can install a truncated store. And never
# background or start anything long-lived inside a critical section: a child
# process inherits fd 9 and keeps the lock held after the group itself ends.
locked() { # locked <command...>
  {
    flock -w 5 9 || { log "lock: timed out after 5s"; exit 1; }
    "$@"
  } 9>"$LOCK"
}

# Critical sections, run under `locked`. The metadata stamp is inside on
# purpose: stamped outside, two presses could write 4 then 5 but stamp 5 then 4,
# leaving the sidebar disagreeing with the store. Toasts stay outside.
rank_write() { # rank_write <pane_id> <priority|"">
  store_set "$1" "$2"
  # rank_write runs under `locked` as a plain command (never in a condition,
  # per that contract), so a bare failure here would abort silently with the
  # lock still released on process exit. Log first so a run of these shows up
  # instead of the sidebar just quietly disagreeing with the store.
  stamp_one "$1" "$2" || {
    log "rank_write: stamp failed for $1 (store updated, token stale until next stamp)"
    exit 1
  }
}

# Batch clear for the picker's alt+0 sweep, run under `locked` as a plain
# command like rank_write. Snapshots which of the given (already-live-checked)
# panes currently carry a rank, rewrites the store once, then stamps each
# cleared pane individually.
#
# Deliberately NOT rank_write's fatal-on-stamp-failure policy: rank_write is
# one keypress touching one pane, so dying on a failed stamp just leaves that
# one pane's token stale until the next press. A sweep can name a dozen panes,
# and one of them failing to stamp must not cost the other eleven their store
# writes (which have already landed) or their own stamps — so a stamp failure
# here is logged and the loop moves on, same as the ticker's per-pane writes.
clear_many_write() { # clear_many_write <live pane ids, space/newline separated>; sets $cleared, $cleared_count
  cleared=''
  for p in $1; do
    [ -n "$(stored "$p")" ] || continue
    cleared="$cleared $p"
  done
  crit_delay
  if [ -n "$cleared" ]; then
    tmp=$(mktemp "$STORE.XXXXXX")
    awk -F'\t' -v panes="$cleared" '
      BEGIN { n = split(panes, arr, " "); for (i = 1; i <= n; i++) if (arr[i] != "") drop[arr[i]] = 1 }
      !($1 in drop)
    ' "$STORE" >"$tmp"
    mv "$tmp" "$STORE"
    for p in $cleared; do
      stamp_one "$p" "" ||
        log "clear-many: stamp failed for $p (store updated, token stale until next stamp)"
    done
  fi
  cleared_count=0
  for p in $cleared; do cleared_count=$((cleared_count + 1)); done
}

rank_step() { # rank_step <pane_id> <up|down>; sets $next
  cur=$(stored "$1")
  case $cur in 1 | 2 | 3 | 4 | 5) ;; *) cur=$DEFAULT ;; esac
  crit_delay
  if [ "$2" = up ]; then
    next=$((cur + 1))
    [ "$next" -le 5 ] || next=5
  else
    next=$((cur - 1))
    [ "$next" -ge 1 ] || next=1
  fi
  [ "$next" != "$DEFAULT" ] || next=''
  rank_write "$1" "$next"
}

apply() { # apply <pane_id> <priority|"">
  locked rank_write "$1" "$2"
  notify "$1" "$2"
}

# Focus a pane so the CLIENT actually moves.
#
# `herdr agent focus` on its own is not enough, and this is the whole reason the
# keybinds looked dead. agent.focus is NOT in the server's client-shell method
# allowlist (src/server/client_commands.rs), so it only updates server-side
# state; the attached client keeps its own idea of focus and overwrites it
# within a second or two. Measured directly: focus a pane in another space with
# agent focus and it reads back correct immediately, then reverts.
#
# workspace.focus and tab.focus ARE on that allowlist, so they are routed to the
# client and drag the view along. The trio holds. There is no CLI route to
# client-side focus of one pane inside a tab, so the pane-level part still rides
# on agent focus, which is enough once the client is already on the right tab.
focus_pane() { # focus_pane <pane_id>
  row=$(herdr pane list | jq -r --arg p "$1" \
    'first(.result.panes[] | select(.pane_id == $p) | "\(.workspace_id) \(.tab_id)") // empty')
  [ -n "$row" ] || return 0
  herdr agent focus "$1" >/dev/null 2>&1 || true
  herdr workspace focus "${row%% *}" >/dev/null 2>&1 || true
  herdr tab focus "${row#* }" >/dev/null 2>&1 || true
}

# The queue goto walks. Highest priority first; within a band, blocked first
# (one keystroke away from running again, so it costs you seconds rather than a
# review), then done, then idle; then longest-waiting.
#
# IDLE IS IN THE QUEUE ON PURPOSE. It used to be excluded on the grounds that an
# idle agent had already been dealt with, which was only true while the fork
# kept `done` sticky until you typed. On stock herdr, merely focusing a pane
# acknowledges it and flips done to idle — so excluding idle meant visiting a
# session silently removed it from the ranking, which is the losing-track
# problem this whole thing exists to solve. Including it makes the queue mean
# "everything of yours that is not currently running", which does not depend on
# the acknowledgement rule at all, and let the fork be dropped.
#
# `working` and snoozed panes are excluded now. A working agent genuinely
# wants nothing, and a snoozed one has said "not right now".
#
# That last key is load-bearing, not decoration. Most agents sit at the default
# rank, so without a deterministic tiebreak the head of the queue shuffles as
# soon as anything about an agent changes, and "go to the top and stay there"
# walks off somewhere new on every press. state_change_seq is monotonic and does
# not move when a pane is merely focused.
queue() {
  # Snoozed panes are not in the queue at all, so alt+g cannot land on them.
  # Read into a variable first, outside any pipeline, so a failing
  # snoozes_active is caught here rather than swallowed by the exit status of
  # whatever it's piped into. Failing OPEN (not filtering) is deliberate: a
  # working alt+g that shows a snoozed pane beats an aborted one.
  ids=$(snoozes_active) || { log "queue: snooze read failed, not filtering"; ids=''; }
  # IN rather than `inside`: on arrays of strings `inside` matches substrings,
  # so "w1:p1" would count as inside ["w1:p10"].
  snoozed=$(printf '%s\n' "$ids" | cut -f1 | jq -R -s -c 'split("\n") | map(select(length > 0))')
  herdr agent list | jq -r --argjson def "$DEFAULT" --argjson snoozed "$snoozed" '
    [ .result.agents[]
      | select(.agent_status == "blocked" or .agent_status == "done"
               or .agent_status == "idle")
      | select(.pane_id | IN($snoozed[]) | not)
      | { pane_id,
          focused,
          status: .agent_status,
          title: (.terminal_title_stripped // .terminal_title // ""),
          seq: .state_change_seq,
          pri: (((.tokens.pri // "") | ltrimstr("P") | tonumber?) // $def) } ]
    | sort_by(-.pri,
        (if .status == "blocked" then 0 elif .status == "done" then 1 else 2 end),
        .seq)
    | .[]
    | [ .pane_id, (.pri | tostring), .status, (if .focused then "*" else "-" end), .title ]
    | @tsv'
}

# Every agent, ranked, for the picker. Unlike queue() this keeps working and
# idle sessions in the list: the picker is the view of *everything you have on*,
# which is the question "what should I be doing" actually needs. Ranked first,
# then blocked, done, working, idle within a band.
#
# Field 1 is the pane id and stays hidden in fzf; everything after it is the
# display line. jq does the truncating, because its string slicing counts
# codepoints and will not cut a multi-byte character in half; awk does the
# padding and the colour.
rows() {
  # Workspace and tab labels are not on the agent record, only their ids, so
  # they come from two extra list calls and get joined in jq. Three API calls
  # per reload, each a few milliseconds; the picker redraws rarely enough that
  # readability is worth more than the round trips.
  ws=$(herdr workspace list |
    jq -c '[.result.workspaces[] | {key: .workspace_id, value: (.label // .workspace_id)}] | from_entries')
  tabs=$(herdr tab list |
    jq -c '[.result.tabs[] | {key: .tab_id, value: (.label // .tab_id)}] | from_entries')

  # Fail open like queue(): a failed snooze read just marks nothing, rather
  # than emptying the picker. snooze_step keeps one line per pane; only a hand
  # edit can leave two (prune keeps them as they are), and from_entries then
  # shows the last.
  ids=$(snoozes_active) || { log "rows: snooze read failed, not marking"; ids=''; }
  snoozed=$(printf '%s\n' "$ids" | jq -R -s -c \
    '[split("\n")[] | select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber)}] | from_entries')

  herdr agent list |
    jq -r --argjson def "$DEFAULT" --argjson ws "$ws" --argjson tabs "$tabs" --argjson snoozed "$snoozed" '
    [ .result.agents[]
      | { pane_id,
          focused,
          status: .agent_status,
          workspace: (($ws[.workspace_id] // .workspace_id) | .[0:14]),
          tab: (($tabs[.tab_id] // .tab_id) | .[0:18]),
          title: (.terminal_title_stripped // .terminal_title // ""),
          ranked: (((.tokens.pri // "") | length) > 0),
          seq: .state_change_seq,
          wake: $snoozed[.pane_id],
          pri: (((.tokens.pri // "") | ltrimstr("P") | tonumber?) // $def) } ]
    | sort_by(-.pri,
        (if .wake then 1 else 0 end),
        (if .status == "blocked" then 0
         elif .status == "done" then 1
         elif .status == "working" then 2
         else 3 end),
        .seq)
    | .[]
    | [ .pane_id,
        (if .ranked then "P\(.pri)" else "--" end),
        (if .wake then "zz \(.wake | strflocaltime("%H:%M"))" else .status end),
        .workspace,
        .tab,
        (if .focused then ">" else " " end),
        .title ]
    | @tsv' |
    awk -F'\t' '
      BEGIN { R = "\033[0m"; B = "\033[1m"; D = "\033[2m" }
      {
        if ($3 == "blocked")      sc = "\033[31m"
        else if ($3 == "done")    sc = "\033[36m"
        else if ($3 == "working") sc = "\033[33m"
        else                      sc = D
        pc = ($2 == "--") ? D : B
        printf "%s\t%s%s%s %s%-2s%s %s%-8s%s %s%-14s%s %s%-18s%s %s\n", \
          $1, B, $6, R, pc, $2, R, sc, $3, R, D, $4, R, D, $5, R, $7
      }'
}

SELF="$HOME/.config/herdr/herdr-agent-priority.sh"

cmd=${1:-}
[ -n "$cmd" ] || die "usage: $0 {up|down|set <1-5>|clear|clear-many <file>|snooze|goto|pick|rows|stamp|list} [pane_id]"
shift
log "run $cmd $* (herdr=$(command -v herdr || echo MISSING))"

case $cmd in
up | down)
  pane=$(target_pane "${1:-}")
  [ -n "$pane" ] || exit 0
  locked rank_step "$pane" "$cmd"
  notify "$pane" "$next"
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

clear-many)
  # Driven by the picker's alt+0: <file> is fzf's {*f} for the current query
  # — the FULL matched rows, one per line, each pane_id<TAB>display-text (the
  # display half carries the ANSI colour codes rows() emits, and may itself
  # contain spaces; only the id is used). {*1f} looks like the right tool
  # here — field 1, file flag — but fzf 0.74.3 does not expand it at all: it
  # passes the literal string `{*1f}` through unchanged, so an early version
  # of this bind silently no-op'd (verified against real fzf under `script`,
  # not just read off the man page). {*f} does expand, so the field-1 cut
  # happens here instead. `cut -f1` also does the right thing for a plain
  # one-id-per-line file (a line with no tab is entirely field 1), which is
  # what the offline test harness and a hand-written list both use.
  #
  # A missing or empty file is a plain no-op — no agent list call, no lock,
  # no toast — so an accidental press over an empty filter costs nothing.
  file=${1:-}
  [ -n "$file" ] && [ -s "$file" ] || exit 0
  # The one required `herdr agent list` call: anything in the file that is
  # not a live pane right now is skipped and logged, never written.
  list=$(herdr agent list) || { log "clear-many: agent list failed"; exit 0; }
  live=$(printf '%s\n' "$list" | jq -r '.result.agents[].pane_id')
  panes=''
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    p=$(printf '%s\n' "$line" | cut -f1)
    [ -n "$p" ] || continue
    if printf '%s\n' "$live" | grep -qxF "$p"; then
      panes="$panes $p"
    else
      log "clear-many: $p not a live agent, skipped"
    fi
  done <"$file"
  locked clear_many_write "$panes"
  case $cleared_count in
  0) toast "No ranks to clear" "" ;;
  1) toast "Cleared 1 rank" "" ;;
  *) toast "Cleared $cleared_count ranks" "" ;;
  esac
  ;;

snooze)
  # Each press moves one rung from wherever the pane is now; past 4h it is off.
  # Focus stays put so the key can be pressed again, and alt+g already skips
  # the pane, so the next alt+g goes somewhere else by itself.
  pane=$(target_pane "${1:-}")
  [ -n "$pane" ] || exit 0
  locked snooze_step "$pane"
  # After the lock, never inside it. Off needs no ticker: the label is already
  # cleared, and a running ticker notices the empty store on its next pass.
  [ -z "$step" ] || ensure_ticker
  title=$(pane_title "$pane")
  [ -n "$title" ] || title="$pane"
  if [ -n "$step" ]; then
    toast "Snoozed $(snooze_label "$step")" "$title · until $(date -d "@$wake" +%H:%M)"
  else
    toast "Snooze off" "$title"
  fi
  ;;

goto)
  # Cycle the TOP BAND, never further down it.
  #
  # The band is every waiting agent sharing the highest rank present. Three
  # priority-5 sessions means alt+g walks those three and wraps; it will not
  # quietly drop you onto a 4 just because you pressed again. Pressing past the
  # things you called most important is how a ranking rots into a to-do list.
  #
  # When the band holds exactly one and you are on it, it says so rather than
  # moving. Answering an agent starts it working, and working is the one status
  # the queue excludes, so it leaves the band by itself. If it is still sitting
  # there, the usual reason is that its rank is stale, so the toast offers the
  # demote key first and the picker second. The keys are read from config.toml
  # so the hint cannot drift from the bindings.
  q=$(queue)
  if [ -z "$q" ]; then
    # An empty queue usually means nothing is waiting, but it can also mean
    # everything that would be is snoozed — a silent exit then looks
    # indistinguishable from "you're caught up", which is the wrong message.
    #
    # A snooze on its own is not enough to say so, though: it may belong to a
    # working or already-gone pane, which was never going to be in the queue
    # anyway. So the wake map is joined against a fresh agent list, the same
    # way rows() joins its workspace/tab maps, and only snoozed panes that are
    # actually blocked/done/idle right now count. Failing to read that list
    # fails open to no toast, same as everywhere else this is read.
    active=$(snoozes_active) || active=''
    wake=''
    if [ -n "$active" ]; then
      snoozed_map=$(printf '%s\n' "$active" | jq -R -s -c '
        split("\n") | map(select(length > 0) | split("\t"))
        | map({key: .[0], value: (.[1] | tonumber)}) | from_entries')
      wake=$(herdr agent list | jq -r --argjson wake "$snoozed_map" '
        [ .result.agents[]
          | select(.agent_status == "blocked" or .agent_status == "done"
                   or .agent_status == "idle")
          | select(.pane_id as $p | $wake | has($p))
          | $wake[.pane_id] ]
        | sort | .[0] // empty') || wake=''
    fi
    if [ -n "$wake" ]; then
      log "goto: everything waiting is snoozed, next back $(date -d "@$wake" +%H:%M)"
      toast "Everything waiting is snoozed" "next back $(date -d "@$wake" +%H:%M)"
    fi
    exit 0
  fi
  top=$(printf '%s\n' "$q" | head -1 | cut -f2)
  band=$(printf '%s\n' "$q" | awk -F'\t' -v p="$top" '$2 == p')
  count=$(printf '%s\n' "$band" | grep -c '')
  on_it=$(printf '%s\n' "$band" | cut -f4 | grep -c '^\*$' || true)
  if [ "$count" -eq 1 ] && [ "$on_it" -eq 1 ]; then
    head_row=$(printf '%s\n' "$band" | head -1)
    log "goto already at the top ($(printf '%s\n' "$head_row" | cut -f1))"
    hint=''
    k=$(keybind_for down)
    [ -z "$k" ] || hint="$k to lower it"
    k=$(keybind_for open)
    [ -z "$k" ] || hint="${hint:+$hint · }$k to pick another"
    toast "Top of the ranking" "$(printf '%s\n' "$head_row" | cut -f5)${hint:+ · $hint}"
    exit 0
  fi
  target=$(printf '%s\n' "$band" | awk -F'\t' '
    { pane[NR] = $1; if ($4 == "*") here = NR }
    END { if (NR) print pane[(here % NR) + 1] }')
  [ -n "$target" ] || exit 0
  log "goto focusing $target (band P$top, $count member(s))"
  focus_pane "$target"
  ;;

rows)
  rows
  ;;

pick)
  # Runs inside the plugin popup, which gets every keystroke including Escape.
  # alt+1-5 re-rank the highlighted row in place and reload the list, so the
  # popup is both the view and the way to set a priority without leaving it.
  #
  # Typing always filters; every command is an alt chord, so no letter or digit
  # is ever taken from the query and the query survives each reload. That makes
  # chains like  herdr, alt+z, ctrl+backspace, smarticipate re, alt+shift+p
  # one continuous gesture.
  #
  # --track --id-nth 1 keeps the cursor on the same pane (field 1 is the hidden
  # pane id) when a reload re-sorts the list; without it a re-rank moves the row
  # out from under the cursor and the next alt+shift+p hits a different agent.
  # fzf's default for ctrl-bspace deletes one character, hence the rebind.
  #
  # SET-AND-ADVANCE. alt+1-5's chain is execute-silent(...)+down+reload(...):
  # `down` moves the cursor before `reload` runs, so --track's id-nth capture
  # happens against the row that was *below* the one just ranked, not the one
  # just moved away by the re-sort. fzf's man page: "Multiple actions can be
  # chained using + separator" (ACTION COMPOSITION), evaluated left to right,
  # and --id-nth's own entry says --track "extracts the tracking key from the
  # current item using the nth expression and searches for a matching item in
  # the reloaded list" — i.e. whatever is current *at reload time*, which by
  # then is the row below. Net effect: the cursor stays put on screen while
  # sweeping ranks down a list. --cycle is still on, so `down` on the last row
  # wraps to the first rather than stopping — a sweep that starts at the
  # bottom of the list wraps around instead of leaving the cursor off the end;
  # accepted, not treated as a bug.
  #
  # alt+p/alt+shift+p/alt+z do NOT chain +down: nudging and snoozing act
  # in place and repeated presses must keep hitting the same row, which is
  # exactly what dropping the extra `down` preserves.
  #
  # alt+0 clears every row the current query matches, not just the
  # highlighted one: {*f} is fzf's all-matched-items placeholder ("a
  # placeholder expression starting with * flag will be replaced to the
  # space-separated list of all matched items individually quoted",
  # PREVIEW WINDOW section) with the f flag, which writes that list to a temp
  # file instead of inlining it ("a placeholder expression with f flag is
  # replaced to the path of a temporary file that holds the evaluated
  # list") — {*f}'s own man-page example. An empty query matches every row,
  # so alt+0 with nothing typed clears everyone.
  #
  # NOT {*1f}. Narrowing to field 1 first looks like the obvious move — the
  # file would then hold bare pane ids — but measured against real fzf
  # 0.74.3 (under `script`, to get a pty), {*1f} is not expanded at all: fzf
  # passes the literal five characters `{*1f}` straight through, silently.
  # {*1} (inline, no file) and {*f} (file, no field narrowing) both do
  # expand. So {*f} is used as-is — the file holds full matched rows,
  # pane_id<TAB>display-text — and `clear-many` itself does the field-1 cut
  # (see its comment).
  command -v fzf >/dev/null || die "pick needs fzf"
  sel=$(rows | fzf \
    --delimiter='\t' --with-nth=2.. --no-sort --cycle --ansi \
    --track --id-nth=1 \
    --prompt='agent > ' \
    --header='enter jump  ·  alt+p/alt+shift+p nudge  ·  alt+z snooze  ·  alt+1-5 rank (3 = unranked)  ·  alt+0 clear matched  ·  esc close' \
    --bind='ctrl-bspace:backward-kill-word' \
    --bind="alt-1:execute-silent($SELF set 1 {1})+down+reload($SELF rows)" \
    --bind="alt-2:execute-silent($SELF set 2 {1})+down+reload($SELF rows)" \
    --bind="alt-3:execute-silent($SELF clear {1})+down+reload($SELF rows)" \
    --bind="alt-4:execute-silent($SELF set 4 {1})+down+reload($SELF rows)" \
    --bind="alt-5:execute-silent($SELF set 5 {1})+down+reload($SELF rows)" \
    --bind="alt-p:execute-silent($SELF up {1})+reload($SELF rows)" \
    --bind="alt-P:execute-silent($SELF down {1})+reload($SELF rows)" \
    --bind="alt-z:execute-silent($SELF snooze {1})+reload($SELF rows)" \
    --bind="alt-0:execute-silent($SELF clear-many {*f})+reload($SELF rows)" || true)
  [ -n "$sel" ] || exit 0
  target=$(printf '%s\n' "$sel" | cut -f1)
  [ -n "$target" ] || exit 0
  # Hand the choice to `open` rather than focusing here. Focusing from inside
  # the popup looks like it works — the call returns ok and the API reports the
  # pane focused — but the session puts focus back where it was as the popup
  # closes. Measured, not assumed. Detaching the call does not help either: the
  # popup's pty dies with it and takes any orphan along.
  log "pick chose $target"
  printf '%s\n' "$target" >"$SELECTION.tmp" && mv "$SELECTION.tmp" "$SELECTION"
  ;;

open)
  # Runs from the keybind, so it is a child of the server rather than of the
  # popup, and outlives it. Opens the picker, waits for a choice to appear, then
  # focuses once the popup is gone and the focus will stick.
  : >"$SELECTION"
  herdr plugin pane open --plugin agent-priority --entrypoint picker >/dev/null || {
    log "open: plugin pane open failed"
    exit 0
  }
  i=0
  while [ "$i" -lt 600 ]; do
    if [ -s "$SELECTION" ]; then
      target=$(cat "$SELECTION")
      : >"$SELECTION"
      [ -n "$target" ] || exit 0
      log "open: focusing $target"
      focus_pane "$target"
      exit 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  log "open: no choice within 60s"
  ;;

stamp)
  # Startup hook. See prune()'s comment for why the prisort reconcile lives in
  # there too, under the same lock, rather than after it.
  locked prune
  set_view
  # After the lock, never inside it. Cheap to skip: this hook fires on every
  # pane.agent_detected, and most of the time nothing is snoozed.
  snoozed_now=$(snoozes_active) || snoozed_now=''
  [ -z "$snoozed_now" ] || ensure_ticker
  ;;

view)
  set_view
  ;;

list)
  queue | awk -F'\t' '{ printf "P%s  %-8s %-8s %s %s\n", $2, $3, $1, ($4 == "*" ? ">" : " "), $5 }'
  ;;

ticker)
  # Started detached by ensure_ticker; see the THE TICKER comment above.
  # A pass right away (so a restart's labels come back at once), then one a
  # minute. Each pass opens and closes fd 9 through `tick_locked`, so between
  # passes it holds no store lock. The agent list is read before that lock
  # (tick_read_agents); only the store read that decides whether to keep
  # running happens inside it.
  exec 8>"$TICKER_LOCK"
  flock -n 8 || { log "ticker: already running"; exit 0; }
  log "ticker: started"
  while :; do
    ticker_exit=''
    tick_read_agents
    tick_locked
    [ -z "$ticker_exit" ] || exit 0
    # Test seam: exactly one pass.
    [ -z "${AGENT_PRIORITY_TICK_ONCE:-}" ] || exit 0
    # 8>&-: a child that inherited fd 8 keeps the singleton after the ticker
    # dies (measured), so if this shell is killed mid-wait, a sleeping child
    # must not block the replacement for up to a minute.
    sleep 60 8>&-
  done
  ;;

*)
  die "unknown command: $cmd"
  ;;
esac
