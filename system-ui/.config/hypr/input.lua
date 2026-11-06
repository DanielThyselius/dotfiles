-- Personal input overrides (migrated from input.conf, 2026-09-06).

hl.config({
  input = {
    kb_layout = "se",
    -- Caps Lock is the compose key, as before Omarchy 4.5 moved it to Shift + Caps Lock.
    kb_options = "compose:caps",
    repeat_delay = 600,

    -- Focus follows mouse hover. Paired with touchpad disable_while_typing below
    -- so palm/wrist touches during typing don't shift focus.
    follow_mouse = 1,
    sensitivity = 0.3,

    touchpad = {
      natural_scroll = true,
      -- Ignore touchpad while keys are being pressed — prevents palm/wrist
      -- touches from moving the cursor (and tripping follow_mouse = 1).
      disable_while_typing = true,
    },
  },
})

-- App-specific touchpad scroll speeds.
o.window("(Alacritty|kitty|foot)", { scroll_touchpad = 2.25 })
o.window("com.mitchellh.ghostty", { scroll_touchpad = 0.3 })

-- Speed up scrolling on the external mouse only (leave the trackpad alone).
-- Names must match `hyprctl devices` exactly; the undocked endpoint may
-- enumerate as plain razer-razer-viper-ultimate on newer builds.
hl.device({ name = "razer-razer-viper-ultimate-1", scroll_factor = 5.0 })
hl.device({ name = "razer-razer-viper-ultimate-dongle-1", scroll_factor = 5.0 })
hl.device({ name = "razer-razer-mouse-dock-1", scroll_factor = 5.0 })

-- 3-finger horizontal swipe changes workspace.
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
