-- Default config for the Go language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/gopls.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'gopls' },
  filetypes = { 'go', 'gomod', 'gowork', 'gotmpl' },
  root_markers = { 'go.work', 'go.mod', '.git' },
}
