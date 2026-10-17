-- Default config for the Zig language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/zls.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'zls' },
  filetypes = { 'zig', 'zir' },
  root_markers = { 'zls.json', 'build.zig', '.git' },
}
