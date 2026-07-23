-- Buffer-local settings for `.http` files.
--
-- Keymaps are NOT set here — they're attached by
-- `require('tachydromos').setup()` via a `FileType http` autocommand (see
-- lua/tachydromos/init.lua), so nothing binds unless the user has actually
-- called setup(), matching mini.nvim's "inert until setup()" convention.
if vim.b.did_ftplugin_tachydromos then return end
vim.b.did_ftplugin_tachydromos = true

vim.bo.commentstring = '# %s'
