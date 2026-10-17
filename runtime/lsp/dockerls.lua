-- Default config for the Dockerfile language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/dockerls.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'docker-langserver', '--stdio' },
  filetypes = { 'dockerfile' },
  root_markers = { 'Dockerfile', '.git' },
}
