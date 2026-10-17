-- Default config for the CSS language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/cssls.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'vscode-css-language-server', '--stdio' },
  filetypes = { 'css', 'scss', 'less' },
  root_markers = { 'package.json', '.git' },
}
