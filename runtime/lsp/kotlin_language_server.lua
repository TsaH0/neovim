-- Default config for the Kotlin language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/kotlin_language_server.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'kotlin-language-server' },
  filetypes = { 'kotlin' },
  root_markers = {
    'settings.gradle',
    'settings.gradle.kts',
    'build.gradle',
    'build.gradle.kts',
    'pom.xml',
    '.git',
  },
}
