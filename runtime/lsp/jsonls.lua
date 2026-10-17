-- Default config for the JSON language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/jsonls.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'vscode-json-language-server', '--stdio' },
  filetypes = { 'json', 'jsonc' },
  root_markers = { '.git' },
}
