-- Default config for the Python linter/formatter (ruff) language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/ruff.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'ruff', 'server' },
  filetypes = { 'python' },
  root_markers = { 'pyproject.toml', 'ruff.toml', '.ruff.toml', '.git' },
}
