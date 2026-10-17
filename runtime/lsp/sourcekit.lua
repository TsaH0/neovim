-- Default config for the Swift language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/sourcekit.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'sourcekit-lsp' },
  filetypes = { 'swift', 'objc', 'objcpp' },
  root_markers = { 'Package.swift', '.git' },
}
