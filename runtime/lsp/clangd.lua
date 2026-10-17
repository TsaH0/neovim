-- Default config for the C/C++ (clangd) language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/clangd.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'clangd' },
  filetypes = { 'c', 'cpp', 'objc', 'objcpp', 'cuda' },
  root_markers = {
    '.clangd',
    '.clang-tidy',
    '.clang-format',
    'compile_commands.json',
    'compile_flags.txt',
    'configure.ac',
    '.git',
  },
}
