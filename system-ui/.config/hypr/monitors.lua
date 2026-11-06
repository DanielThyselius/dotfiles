-- Personal monitor + workspace layout (migrated from monitors.conf, 2026-09-06).

-- Leave GDK_SCALE unset so GTK apps use Wayland fractional per-monitor scaling
-- (Omarchy's default is 2, which forces integer scaling).
hl.env("GDK_SCALE", "")

hl.monitor({ output = "HDMI-A-1", mode = "2560x1440@144", position = "0x0", scale = 1 })
hl.monitor({ output = "DP-1", mode = "preferred", position = "0x0", scale = 2 })
-- Yealink conference display: mirror the laptop instead of extending.
-- Matched by description so it doesn't affect the office DP-1 rule above;
-- it must come AFTER that rule: the last matching hl.monitor rule wins.
hl.monitor({ output = "desc:VCS Yealink", mode = "preferred", position = "auto", scale = 1, mirror = "eDP-1" })
hl.monitor({ output = "DP-2", mode = "preferred", position = "0x0", scale = 1.5 })
-- Laptop position is set for the home HDMI stacked layout (below the external,
-- left-aligned). Office DP-1/DP-2 setups expect the laptop to the right — when
-- switching setups, this position needs to change too.
hl.monitor({ output = "eDP-1", mode = "2560x1600@300", position = "0x1440", scale = 1.25 })

-- Workspace pinning with global numbering (see global-workspaces.lua), all
-- persistent so they're always present:
--   1-5  -> home external (HDMI-A-1)
--   6-10 -> laptop (eDP-1)
-- Only one rule per workspace id; in non-home setups (e.g. office DP) 1-5 won't
-- follow an external automatically. Hyprland moves an unplugged screen's
-- workspaces to the laptop and returns them on replug.
hl.workspace_rule({ workspace = "1", monitor = "HDMI-A-1", persistent = true, default = true })
hl.workspace_rule({ workspace = "2", monitor = "HDMI-A-1", persistent = true })
hl.workspace_rule({ workspace = "3", monitor = "HDMI-A-1", persistent = true })
hl.workspace_rule({ workspace = "4", monitor = "HDMI-A-1", persistent = true })
hl.workspace_rule({ workspace = "5", monitor = "HDMI-A-1", persistent = true })
hl.workspace_rule({ workspace = "6", monitor = "eDP-1", persistent = true, default = true })
hl.workspace_rule({ workspace = "7", monitor = "eDP-1", persistent = true })
hl.workspace_rule({ workspace = "8", monitor = "eDP-1", persistent = true })
hl.workspace_rule({ workspace = "9", monitor = "eDP-1", persistent = true })
hl.workspace_rule({ workspace = "10", monitor = "eDP-1", persistent = true })
