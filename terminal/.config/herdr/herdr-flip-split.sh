#!/bin/sh
# Flip the split direction of a two-pane tab, in place.
#
#   herdr-flip-split.sh
#
# Side-by-side becomes stacked and vice versa, keeping both panes and their
# running processes. tmux does this with `select-layout even-horizontal` /
# `even-vertical`; herdr has no equivalent action, and the two obvious
# candidates both dead-end:
#
#   `herdr pane move` refuses to reparent within the pane's own tab -- it
#   returns {"changed": false, "reason": "same_tab"} and does nothing.
#
#   `layout.apply` (socket API only, no CLI verb) looks made for this, since
#   layout.export hands back a tree with a flippable `direction`. It is a
#   trap: applying a layout TEARS DOWN the target tab and rebuilds it with
#   fresh panes under a new tab id, killing whatever was running. It builds
#   layouts, it does not rearrange them.
#
# So: move the second pane out to a scratch tab, then immediately back onto
# the first with the opposite split. Verified that pane ids AND terminal ids
# survive the round trip, so processes keep running; the scratch tab drops
# itself the moment it is emptied, so there is nothing to clean up.
#
# Always moves the SECOND pane so first/second order is preserved -- moving
# the first would silently swap the panes as well as flip them.
set -eu

layout=$(herdr pane layout --current)

count=$(printf '%s' "$layout" | jq '.result.layout.panes | length')
if [ "$count" -ne 2 ]; then
    herdr notification show "Flip split" \
        --body "Needs exactly 2 panes in the tab (found $count)" \
        --sound none >/dev/null 2>&1 || true
    exit 0
fi

dir=$(printf '%s' "$layout" | jq -r '.result.layout.splits[0].direction')
case "$dir" in
    right|left) new=down;  axis=x ;;
    down|up)    new=right; axis=y ;;
    *)          exit 0 ;;
esac

# Second pane = the one further along the split axis.
first=$(printf '%s' "$layout" | jq -r --arg a "$axis" \
    '[.result.layout.panes[]] | sort_by(.rect[$a]) | .[0].pane_id')
second=$(printf '%s' "$layout" | jq -r --arg a "$axis" \
    '[.result.layout.panes[]] | sort_by(.rect[$a]) | .[1].pane_id')
focused=$(printf '%s' "$layout" | jq -r '.result.layout.focused_pane_id')

tab=$(herdr pane get "$second" | jq -r '.result.pane.tab_id')

herdr pane move "$second" --new-tab >/dev/null
herdr pane move "$second" --tab "$tab" --target-pane "$first" --split "$new" >/dev/null

# The round trip drags focus onto the moved pane whether or not --focus is
# passed, so put it back by hand when the user was on the other one. After the
# flip `first` is always up/left of `second`, so one directional hop suffices.
if [ "$focused" != "$second" ]; then
    case "$new" in
        down)  herdr pane focus --direction up   >/dev/null ;;
        right) herdr pane focus --direction left >/dev/null ;;
    esac
fi
