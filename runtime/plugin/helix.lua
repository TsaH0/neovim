-- Helix keymap and selection model (`:help helix-mode`).
-- Disable with `vim.g.helix_mode = false` in your config.
if vim.g.loaded_helix ~= nil then
  return
end
vim.g.loaded_helix = true

if vim.g.helix_mode == false or vim.env.NVIM_HELIX_MODE == '0' then
  return
end

require('nvim.helix').setup(type(vim.g.helix_mode) == 'table' and vim.g.helix_mode or nil)
