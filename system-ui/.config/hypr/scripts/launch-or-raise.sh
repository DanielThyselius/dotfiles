#!/bin/bash
# Like omarchy-launch-or-focus but also raises the window above siblings
# (needed for scratchpad apps that share special:scratchpad — focuswindow
# alone leaves the window under whichever was last on top).

PATTERN="$1"
LAUNCH="${2:-uwsm-app -- $PATTERN}"

ADDR=$(hyprctl clients -j | \
  jq -r --arg p "$PATTERN" '.[]|select((.class|test("\\b"+$p+"\\b";"i")) or (.title|test("\\b"+$p+"\\b";"i")))|.address' | \
  head -n1)

if [[ -n $ADDR ]]; then
  hyprctl --batch "dispatch focuswindow address:$ADDR ; dispatch bringactivetotop"
else
  eval exec setsid $LAUNCH
fi
