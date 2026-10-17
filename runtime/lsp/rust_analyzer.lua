-- Default config for the Rust language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/rust_analyzer.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'rust-analyzer' },
  filetypes = { 'rust' },
  root_markers = { 'Cargo.toml', 'rust-project.json', '.git' },
}
