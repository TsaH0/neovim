-- Default config for the OCaml language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/ocamllsp.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'ocamllsp' },
  filetypes = { 'ocaml', 'menhir', 'ocamlinterface', 'ocamllex', 'reason', 'dune' },
  root_markers = { 'dune-project', 'dune-workspace', '.git' },
}
