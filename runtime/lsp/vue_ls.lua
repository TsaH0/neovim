-- Default config for the Vue language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/vue_ls.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'vue-language-server', '--stdio' },
  filetypes = { 'vue' },
  root_markers = { 'package.json', '.git' },
}
