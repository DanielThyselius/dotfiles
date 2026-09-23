-- Omarchy owns the active theme and rewrites this file on every theme switch.
-- Load it by path (like the terminals' includes) rather than symlinking it.
local path = vim.fn.expand("~/.local/state/omarchy/current/theme/neovim.lua")

if vim.fn.filereadable(path) == 0 then
	vim.notify("Omarchy neovim theme not found: " .. path, vim.log.levels.WARN)
	return {}
end

return dofile(path)
