-- Default config for the Bash language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/bashls.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'bash-language-server', 'start' },
  filetypes = { 'sh', 'bash' },
  root_markers = { '.git' },
}
