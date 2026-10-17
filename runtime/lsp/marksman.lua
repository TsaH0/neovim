-- Default config for the Markdown language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/marksman.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'marksman', 'server' },
  filetypes = { 'markdown' },
  root_markers = { '.marksman.toml', '.git' },
}
