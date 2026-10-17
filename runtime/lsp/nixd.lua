-- Default config for the Nix (nixd) language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/nixd.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'nixd' },
  filetypes = { 'nix' },
  root_markers = { 'flake.nix', '.git' },
}
