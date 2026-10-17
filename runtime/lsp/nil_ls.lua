-- Default config for the Nix (nil) language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/nil_ls.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'nil' },
  filetypes = { 'nix' },
  root_markers = { 'flake.nix', '.git' },
}
