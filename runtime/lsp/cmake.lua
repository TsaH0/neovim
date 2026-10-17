-- Default config for the CMake language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/cmake.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'cmake-language-server' },
  filetypes = { 'cmake' },
  root_markers = { 'CMakePresets.json', 'CTestConfig.cmake', 'build', 'cmake', '.git' },
}
