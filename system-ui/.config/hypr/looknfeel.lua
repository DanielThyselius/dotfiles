-- Personal look'n'feel overrides (migrated from looknfeel.conf, 2026-09-06).

hl.config({
  general = {
    -- No gaps between windows; thin border.
    gaps_in = 0,
    gaps_out = 0,
    border_size = 1,

    -- Don't wrap focus when reaching the edge.
    no_focus_fallback = true,
  },

  decoration = {
    dim_inactive = true,
    dim_strength = 0.15,
  },

  cursor = {
    -- Don't teleport the cursor to the center when changing workspace.
    warp_on_change_workspace = 0,
  },

  dwindle = {
    -- Keep Omarchy's force_split = 2 (spawn based on the focused window's aspect
    -- ratio, not the cursor). precise_mouse_move re-enables cursor-position
    -- placement, but only for mouse drag-and-drop.
    smart_split = false,
    precise_mouse_move = true,
  },
})

-- Remove the border when only one window is on the workspace.
o.window({ float = false, workspace = "w[tv1]" }, { border_size = 0 })
o.window({ float = false, workspace = "f[1]" }, { border_size = 0 })

-- Floating scratchpad apps with explicit placement.
-- Bitwarden: right-anchored. Drop Omarchy's floating-window tag so its
-- center/size rules don't fight our explicit positioning.
o.window("^Bitwarden$", {
  tag = "-floating-window",
  float = true,
  workspace = "special:scratchpad",
  size = { 980, 900 },
  move = { 1048, 190 },
})

-- brain.fm PWA: left-anchored, vertically centered.
o.window(".*dcllmfmjlkpljanfegjgohmlnfipachj.*", {
  float = true,
  workspace = "special:scratchpad",
  size = { 500, 800 },
  move = { 20, "(monitor_h-window_h)/2" },
})

-- Spotify: centered.
o.window("^Spotify$", {
  float = true,
  workspace = "special:scratchpad",
  size = { 1170, 844 },
  move = { 439, 218 },
})

-- Omyview animates its own open/close (fade + scale), so keep Hyprland's layer
-- animation off for it; otherwise the two stack into a double fade.
hl.layer_rule({ match = { namespace = "omyview" }, no_anim = true, animation = "none" })
