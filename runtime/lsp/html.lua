-- Default config for the HTML language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/html.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'vscode-html-language-server', '--stdio' },
  filetypes = { 'html' },
  root_markers = { 'package.json', '.git' },
}
