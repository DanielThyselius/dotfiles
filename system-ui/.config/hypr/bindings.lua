-- Personal keybinding overrides (migrated from bindings.conf, 2026-09-06).
-- Quattro's default bindings changed a lot, so several of these unbind a v4
-- default before rebinding. See current bindings: omarchy menu keybindings --print

-- === Apps ===
o.bind("SUPER + E", "File manager", "uwsm-app -- nautilus --new-window")
o.bind("SUPER + B", "Bitwarden", "~/.config/hypr/scripts/launch-or-raise.sh bitwarden 'uwsm-app -- bitwarden-desktop'")
o.bind("SUPER + M", "Brain.fm", "~/.config/hypr/scripts/launch-or-raise.sh dcllmfmjlkpljanfegjgohmlnfipachj 'uwsm-app -- chromium --profile-directory=Default --app-id=dcllmfmjlkpljanfegjgohmlnfipachj'")

-- Spotify via focus-or-launch (was: default SUPER+SHIFT+M).
hl.unbind("SUPER + SHIFT + M")
o.bind("SUPER + SHIFT + M", "Music", "~/.config/hypr/scripts/launch-or-raise.sh spotify")

-- tmux terminal with auto-start fallback (was: default terminal-tmux).
hl.unbind("SUPER + ALT + RETURN")
o.bind("SUPER + ALT + RETURN", "Tmux", 'uwsm-app -- xdg-terminal-exec --dir="$(omarchy-cmd-terminal-cwd)" bash -c "tmux attach || { systemctl --user start tmux && tmux attach; }"')

-- Disabled app defaults.
hl.unbind("SUPER + SHIFT + CTRL + G") -- was: Google Messages

-- === Tiling / window management ===
-- Resize with SUPER + CTRL + arrows (default: grouped-window focus on L/R).
hl.unbind("SUPER + CTRL + LEFT")
hl.unbind("SUPER + CTRL + RIGHT")
o.bind("SUPER + CTRL + LEFT", "Resize window left", hl.dsp.window.resize({ x = -100, y = 0, relative = true }))
o.bind("SUPER + CTRL + RIGHT", "Resize window right", hl.dsp.window.resize({ x = 100, y = 0, relative = true }))
o.bind("SUPER + CTRL + UP", "Resize window up", hl.dsp.window.resize({ x = 0, y = -100, relative = true }))
o.bind("SUPER + CTRL + DOWN", "Resize window down", hl.dsp.window.resize({ x = 0, y = 100, relative = true }))

-- Move window into group with SUPER + CTRL + SHIFT + arrows.
o.bind("SUPER + CTRL + SHIFT + LEFT", "Move window into group left", hl.dsp.window.move({ into_group = "l" }))
o.bind("SUPER + CTRL + SHIFT + RIGHT", "Move window into group right", hl.dsp.window.move({ into_group = "r" }))
o.bind("SUPER + CTRL + SHIFT + UP", "Move window into group up", hl.dsp.window.move({ into_group = "u" }))
o.bind("SUPER + CTRL + SHIFT + DOWN", "Move window into group down", hl.dsp.window.move({ into_group = "d" }))

-- Cycle grouped windows with SUPER + ALT + arrows (default: move into group).
hl.unbind("SUPER + ALT + LEFT")
hl.unbind("SUPER + ALT + RIGHT")
hl.unbind("SUPER + ALT + UP")
hl.unbind("SUPER + ALT + DOWN")
o.bind("SUPER + ALT + LEFT", "Previous window in group", hl.dsp.group.prev())
o.bind("SUPER + ALT + RIGHT", "Next window in group", hl.dsp.group.next())

-- Group cycling on SUPER + CTRL + TAB (default: former workspace).
hl.unbind("SUPER + CTRL + TAB")
o.bind("SUPER + CTRL + TAB", "Next window in group", hl.dsp.group.next())
o.bind("SUPER + CTRL + SHIFT + TAB", "Previous window in group", hl.dsp.group.prev())

-- Former workspace on SUPER + Q.
o.bind("SUPER + Q", "Former workspace", hl.dsp.focus({ workspace = "previous" }))

-- Move window out of group on SUPER + SHIFT + G (default: Signal).
hl.unbind("SUPER + SHIFT + G")
o.bind("SUPER + SHIFT + G", "Move window out of group", hl.dsp.window.move({ out_of_group = true }))

-- Send window to scratchpad on SUPER + SHIFT + S (default: Google Maps).
hl.unbind("SUPER + SHIFT + S")
o.bind("SUPER + SHIFT + S", "Move window to scratchpad", hl.dsp.window.move({ workspace = "special:scratchpad", follow = false }))

-- Workspace overview on SUPER + P (default: pseudo window); pseudo moved to SUPER + U.
hl.unbind("SUPER + P")
o.bind("SUPER + P", "Workspace overview", "omarchy-shell shell toggle se.mindfulstack.omyview")
-- Same overview on SUPER + § (the key left of 1 on the Swedish layout) and on
-- 3-finger swipe up/down (horizontal 3-finger swipe stays workspace switching, see input.lua).
o.bind("SUPER + SECTION", "Workspace overview", "omarchy-shell shell toggle se.mindfulstack.omyview")
local function toggle_overview()
  hl.dispatch(hl.dsp.exec_cmd("omarchy-shell shell toggle se.mindfulstack.omyview"))
end
hl.gesture({ fingers = 3, direction = "up", action = toggle_overview })
hl.gesture({ fingers = 3, direction = "down", action = toggle_overview })
o.bind("SUPER + U", "Pseudo window", hl.dsp.window.pseudo())

-- === Lock / layout / idle ===
-- Lock on SUPER + L (default: toggle workspace layout); layout toggle -> SUPER+SHIFT+L.
hl.unbind("SUPER + L")
o.bind("SUPER + L", "Lock screen", "omarchy-system-lock")
o.bind("SUPER + SHIFT + L", "Toggle workspace layout", "omarchy-hyprland-workspace-layout-toggle")
-- Toggle idle lock on SUPER + CTRL + L (default: lock system; idle toggle is on CTRL+I in v4).
-- v4's omarchy-toggle-idle is a silent "stay awake" toggle (only a bar indicator),
-- so wrap it to also fire a notification confirming the new state.
hl.unbind("SUPER + CTRL + L")
o.bind("SUPER + CTRL + L", "Toggle idle lock", 'if [ "$(omarchy-toggle-idle)" = disabled ]; then omarchy-notification-send -u low "Staying awake" "Idle lock & screensaver disabled"; else omarchy-notification-send -u low "Idle lock enabled" "Screen will lock when idle"; fi')

-- === Misc ===
o.bind("SUPER + D", "Toggle DND", "omarchy-toggle-notification-silencing")
o.bind("SUPER + SHIFT + T", "Toggle touchpad", "omarchy-toggle-touchpad")

-- Dictation on SUPER + Z (default: SUPER + CTRL + X).
hl.unbind("SUPER + CTRL + X")
o.bind("SUPER + Z", "Toggle dictation", "voxtype record toggle")

-- Free the ALT+TAB / CTRL+ALT+TAB families for tmux.
hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")
hl.unbind("CTRL + ALT + TAB")
hl.unbind("CTRL + ALT + SHIFT + TAB")
