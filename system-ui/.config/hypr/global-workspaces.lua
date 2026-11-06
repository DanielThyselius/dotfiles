-- Global workspace numbering instead of Omarchy 4.5's per-monitor workspaces.
--
-- Omarchy gives every monitor its own 1-10 (default/hypr/monitor-workspaces.lua)
-- and has no setting to turn that off (omacom/omarchy#16213 proposes one). This
-- switches it off from here: Super + N always means workspace N, and the
-- workspace rules in monitors.lua decide which screen each one lives on.
-- Hyprland itself moves an unplugged screen's workspaces to another and brings
-- them back on replug.
--
-- Relies on Omarchy internals (o.workspaces); drop it once a toggle ships.

-- The module renumbers workspaces into per-monitor blocks on start, reload and
-- every monitor change. Its handlers look reconcile up when they fire, so this
-- stops all of it.
o.workspaces.reconcile = function() end

for workspace = 1, 10 do
  local key = "code:" .. tostring(workspace + 9)
  local id = tostring(workspace)
  hl.unbind("SUPER + " .. key)
  hl.unbind("SUPER + SHIFT + " .. key)
  hl.unbind("SUPER + SHIFT + ALT + " .. key)
  o.bind("SUPER + " .. key, "Switch to workspace " .. workspace, hl.dsp.focus({ workspace = id }))
  o.bind("SUPER + SHIFT + " .. key, "Move window to workspace " .. workspace, hl.dsp.window.move({ workspace = id }))
  o.bind("SUPER + SHIFT + ALT + " .. key, "Move window silently to workspace " .. workspace,
    hl.dsp.window.move({ workspace = id, follow = false }))
end

-- Omarchy's version renumbers the workspace into the target monitor's block.
for _, direction in ipairs({ { "LEFT", "l", "left" }, { "RIGHT", "r", "right" }, { "UP", "u", "up" }, { "DOWN", "d", "down" } }) do
  local key, dir, name = direction[1], direction[2], direction[3]
  hl.unbind("SUPER + SHIFT + ALT + " .. key)
  o.bind("SUPER + SHIFT + ALT + " .. key, "Move workspace to " .. name .. " monitor", function()
    local target = hl.get_monitor(dir)
    if target then
      hl.dispatch(hl.dsp.workspace.move({ monitor = target.name }))
    end
  end)
end
