-- Default config for the Python (basedpyright) language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/basedpyright.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'basedpyright-langserver', '--stdio' },
  filetypes = { 'python' },
  root_markers = {
    'pyproject.toml',
    'setup.py',
    'setup.cfg',
    'requirements.txt',
    'Pipfile',
    'pyrightconfig.json',
    '.git',
  },
}
