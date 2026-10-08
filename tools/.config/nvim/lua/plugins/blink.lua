return {
  "saghen/blink.cmp",
  opts = {
    completion = {
      -- Nothing is highlighted until you pick with Up/Down, so Enter on an
      -- untouched menu just inserts a newline; browsing doesn't edit the text.
      list = { selection = { preselect = false, auto_insert = false } },
    },
    keymap = {
      -- Right accepts the highlighted item, or the first one if none is.
      ["<Right>"] = { "select_and_accept", "fallback" },
    },
  },
}
