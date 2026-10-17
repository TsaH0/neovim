-- Default config for the JavaScript/TypeScript language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/ts_ls.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'typescript-language-server', '--stdio' },
  filetypes = { 'javascript', 'javascriptreact', 'typescript', 'typescriptreact' },
  root_markers = { 'tsconfig.json', 'jsconfig.json', 'package.json', '.git' },
}
