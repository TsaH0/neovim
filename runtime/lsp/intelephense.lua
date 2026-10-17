-- Default config for the PHP language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/intelephense.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'intelephense', '--stdio' },
  filetypes = { 'php' },
  root_markers = { 'composer.json', '.git' },
}
