-- Default config for the Haskell language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/hls.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'haskell-language-server-wrapper', '--lsp' },
  filetypes = { 'haskell', 'lhaskell' },
  root_markers = { 'hie.yaml', 'stack.yaml', 'cabal.project', 'package.yaml', '.git' },
}
