-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- Alt+Arrow = Alt+j/k (LazyVim's "move line" bindings) in all 3 modes
vim.keymap.set({ "n", "i", "v" }, "<A-Down>", "<A-j>", { remap = true, desc = "Move Down" })
vim.keymap.set({ "n", "i", "v" }, "<A-Up>", "<A-k>", { remap = true, desc = "Move Up" })

-- Ctrl+Arrow = Ctrl+h/j/k/l (move between windows), replacing LazyVim's
-- Ctrl+Arrow resize, which moves to Ctrl+Shift+Arrow below.
vim.keymap.set("n", "<C-Left>", "<C-h>", { remap = true, desc = "Go to Left Window" })
vim.keymap.set("n", "<C-Down>", "<C-j>", { remap = true, desc = "Go to Lower Window" })
vim.keymap.set("n", "<C-Up>", "<C-k>", { remap = true, desc = "Go to Upper Window" })
vim.keymap.set("n", "<C-Right>", "<C-l>", { remap = true, desc = "Go to Right Window" })

-- Ctrl+Shift+Arrow = resize by pushing a border in the arrow's direction: the
-- right/bottom border if there is a window beyond it, else the left/top one.
-- Free in foot, tmux, herdr and Hyprland; Ghostty would eat Left/Right (tabs).
local function push_border(dir)
	local vertical = dir == "left" or dir == "right"
	local has_next = vim.fn.winnr(vertical and "l" or "j") ~= vim.fn.winnr()
	local grow = (dir == "right" or dir == "down") == has_next
	vim.cmd((vertical and "vertical " or "") .. "resize " .. (grow and "+2" or "-2"))
end
vim.keymap.set("n", "<C-S-Left>", function() push_border("left") end, { desc = "Push Window Border Left" })
vim.keymap.set("n", "<C-S-Right>", function() push_border("right") end, { desc = "Push Window Border Right" })
vim.keymap.set("n", "<C-S-Up>", function() push_border("up") end, { desc = "Push Window Border Up" })
vim.keymap.set("n", "<C-S-Down>", function() push_border("down") end, { desc = "Push Window Border Down" })

-- Ctrl+Tab / Ctrl+Shift+Tab = H/L (LazyVim's previous/next buffer in the bar)
vim.keymap.set("n", "<C-Tab>", "L", { remap = true, desc = "Next Buffer" })
vim.keymap.set("n", "<C-S-Tab>", "H", { remap = true, desc = "Prev Buffer" })
