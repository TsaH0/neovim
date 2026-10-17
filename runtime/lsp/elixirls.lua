-- Default config for the Elixir language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/elixirls.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'elixir-ls' },
  filetypes = { 'elixir', 'eelixir', 'heex', 'surface' },
  root_markers = { 'mix.exs', '.git' },
}
