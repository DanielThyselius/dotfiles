-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- Alt+Arrow = Alt+j/k (LazyVim's "move line" bindings) in all 3 modes
vim.keymap.set({ "n", "i", "v" }, "<A-Down>", "<A-j>", { remap = true, desc = "Move Down" })
vim.keymap.set({ "n", "i", "v" }, "<A-Up>", "<A-k>", { remap = true, desc = "Move Up" })

-- Ctrl+Arrow = Ctrl+h/j/k/l (move between windows), replacing LazyVim's
-- Ctrl+Arrow resize. Resize with Ctrl-w +/-/</> or Ctrl-w = instead.
vim.keymap.set("n", "<C-Left>", "<C-h>", { remap = true, desc = "Go to Left Window" })
vim.keymap.set("n", "<C-Down>", "<C-j>", { remap = true, desc = "Go to Lower Window" })
vim.keymap.set("n", "<C-Up>", "<C-k>", { remap = true, desc = "Go to Upper Window" })
vim.keymap.set("n", "<C-Right>", "<C-l>", { remap = true, desc = "Go to Right Window" })
