-- Default config for the Gleam language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/gleam.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'gleam', 'lsp' },
  filetypes = { 'gleam' },
  root_markers = { 'gleam.toml', '.git' },
}
