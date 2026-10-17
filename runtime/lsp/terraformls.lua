-- Default config for the Terraform language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/terraformls.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'terraform-ls', 'serve' },
  filetypes = { 'terraform', 'terraform-vars' },
  root_markers = { '.terraform', '.git' },
}
