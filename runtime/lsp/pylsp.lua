-- Default config for the Python (python-lsp-server) language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/pylsp.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'pylsp' },
  filetypes = { 'python' },
  root_markers = {
    'pyproject.toml',
    'setup.py',
    'setup.cfg',
    'requirements.txt',
    'Pipfile',
    '.git',
  },
}
