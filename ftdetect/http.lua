-- Detect `*.http` files as filetype `http`. Independent of
-- `require('tachydromos').setup()` — filetype detection works even if the
-- plugin's setup() is never called; only keymaps/commands require setup().
vim.filetype.add({
  extension = {
    http = 'http',
  },
})
