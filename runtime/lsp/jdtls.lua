-- Default config for the Java language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/jdtls.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'jdtls' },
  filetypes = { 'java' },
  root_markers = { 'build.gradle', 'build.gradle.kts', 'pom.xml', 'settings.gradle', '.git' },
}
