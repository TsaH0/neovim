-- Default config for the YAML language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/yamlls.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'yaml-language-server', '--stdio' },
  filetypes = { 'yaml' },
  root_markers = { '.git' },
}
