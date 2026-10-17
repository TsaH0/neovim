-- Default config for the Lua language server, used by |lsp-autodetect|.
-- Override it with vim.lsp.config() or a lsp/lua_ls.lua in your config.
---@type vim.lsp.Config
return {
  cmd = { 'lua-language-server' },
  filetypes = { 'lua' },
  root_markers = { '.luarc.json', '.luarc.jsonc', '.stylua.toml', 'stylua.toml', '.git' },
  settings = {
    Lua = {
      runtime = { version = 'LuaJIT' },
      workspace = { checkThirdParty = false },
    },
  },
}
