-- Default config for the LaTeX language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/texlab.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'texlab' },
  filetypes = { 'tex', 'plaintex', 'bib' },
  root_markers = { '.latexmkrc', '.texlabroot', 'texlabroot', 'Tectonic.toml', '.git' },
}
