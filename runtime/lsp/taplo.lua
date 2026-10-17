-- Default config for the TOML language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/taplo.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'taplo', 'lsp', 'stdio' },
  filetypes = { 'toml' },
  root_markers = { '.taplo.toml', 'taplo.toml', '.git' },
}
