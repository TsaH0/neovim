-- Default config for the Svelte language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/svelte.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'svelteserver', '--stdio' },
  filetypes = { 'svelte' },
  root_markers = { 'package.json', '.git' },
}
