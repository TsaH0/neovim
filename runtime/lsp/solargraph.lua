-- Default config for the Ruby (solargraph) language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/solargraph.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'solargraph', 'stdio' },
  filetypes = { 'ruby' },
  root_markers = { 'Gemfile', '.git' },
}
