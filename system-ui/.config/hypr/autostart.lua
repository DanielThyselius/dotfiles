-- Extra autostart processes (migrated from autostart.conf, 2026-09-06).

-- Load hyprpm-managed plugins on every Hyprland start (otherwise enabled
-- plugins stay inert and any binding referencing them errors out).
o.exec_on_start("hyprpm reload -n")
