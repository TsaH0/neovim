-- Default config for the Ruby (ruby-lsp) language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/ruby_lsp.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'ruby-lsp' },
  filetypes = { 'ruby', 'eruby' },
  root_markers = { 'Gemfile', '.git' },
}
