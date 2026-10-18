--- @brief
--- Automatic language server detection (|lsp-autodetect|): when a buffer of a
--- known filetype is opened, enable (|vim.lsp.enable()|) the language servers
--- for that filetype that are installed (their `cmd` is executable).
---
--- Configs come from `lsp/<name>.lua` in 'runtimepath' (Nvim ships defaults
--- in $VIMRUNTIME/lsp/, nvim-lspconfig or your config can override them) and
--- |vim.lsp.config()|.

local M = {}

--- Servers per filetype. Each group lists alternatives: the first installed
--- one is used (e.g. only one Python type checker).
---@type table<string, string[][]>
M.servers = {
  lua = { { 'lua_ls' } },
  python = { { 'basedpyright', 'pyright', 'pylsp' }, { 'ruff' } },
  javascript = { { 'ts_ls' } },
  javascriptreact = { { 'ts_ls' } },
  typescript = { { 'ts_ls' } },
  typescriptreact = { { 'ts_ls' } },
  rust = { { 'rust_analyzer' } },
  go = { { 'gopls' } },
  gomod = { { 'gopls' } },
  gowork = { { 'gopls' } },
  gotmpl = { { 'gopls' } },
  c = { { 'clangd' } },
  cpp = { { 'clangd' } },
  objc = { { 'clangd', 'sourcekit' } },
  objcpp = { { 'clangd', 'sourcekit' } },
  cuda = { { 'clangd' } },
  sh = { { 'bashls' } },
  bash = { { 'bashls' } },
  json = { { 'jsonls' } },
  jsonc = { { 'jsonls' } },
  css = { { 'cssls' } },
  scss = { { 'cssls' } },
  less = { { 'cssls' } },
  html = { { 'html' } },
  yaml = { { 'yamlls' } },
  toml = { { 'taplo' } },
  markdown = { { 'marksman' } },
  zig = { { 'zls' } },
  nix = { { 'nixd', 'nil_ls' } },
  haskell = { { 'hls' } },
  lhaskell = { { 'hls' } },
  ocaml = { { 'ocamllsp' } },
  ruby = { { 'ruby_lsp', 'solargraph' } },
  eruby = { { 'ruby_lsp' } },
  php = { { 'intelephense' } },
  java = { { 'jdtls' } },
  kotlin = { { 'kotlin_language_server' } },
  swift = { { 'sourcekit' } },
  dockerfile = { { 'dockerls' } },
  terraform = { { 'terraformls' } },
  elixir = { { 'elixirls' } },
  heex = { { 'elixirls' } },
  svelte = { { 'svelte' } },
  vue = { { 'vue_ls' } },
  tex = { { 'texlab' } },
  plaintex = { { 'texlab' } },
  bib = { { 'texlab' } },
  gleam = { { 'gleam' } },
  cmake = { { 'cmake' } },
}

--- Filetypes already checked.
local checked = {} ---@type table<string, true>
--- Executable check results, by server name.
local available = {} ---@type table<string, boolean>

--- Whether the server `name` has a config with an executable `cmd`.
---@param name string
---@return boolean
function M.is_available(name)
  if available[name] == nil then
    local ok, cfg = pcall(function()
      return vim.lsp.config[name]
    end)
    local cmd = ok and cfg and cfg.cmd
    if type(cmd) == 'function' then
      available[name] = true -- Custom transport (e.g. TCP): assume available.
    else
      available[name] = type(cmd) == 'table' and cmd[1] ~= nil and vim.fn.executable(cmd[1]) == 1
    end
  end
  return available[name]
end

--- Servers that would be enabled for filetype `ft`.
---@param ft string
---@return string[]
function M.detect(ft)
  local out = {}
  for _, group in ipairs(M.servers[ft] or {}) do
    for _, name in ipairs(group) do
      if M.is_available(name) then
        out[#out + 1] = name
        break
      end
    end
  end
  return out
end

--- FileType handler: enable the installed servers for `ft` (once per filetype).
---@param ft string
function M.on_filetype(ft)
  if not vim.o.lspautodetect or checked[ft] or not M.servers[ft] then
    return
  end
  checked[ft] = true
  local names = vim.tbl_filter(function(name)
    return not vim.lsp.is_enabled(name)
  end, M.detect(ft))
  if #names > 0 then
    vim.lsp.enable(names)
  end
end

--- Creates (or removes, when `on` is false) the FileType autocommand.
--- Called when 'lspautodetect' is set, and at startup.
---@param on boolean
function M.sync(on)
  local group = vim.api.nvim_create_augroup('nvim.lsp.autodetect', {})
  if not on then
    vim.api.nvim_del_augroup_by_id(group)
    return
  end
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    desc = "Enable installed language servers ('lspautodetect')",
    callback = function(ev)
      if vim.bo[ev.buf].buftype == '' then
        M.on_filetype(ev.match)
      end
    end,
  })
end

--- Forgets cached results (e.g. after installing a server).
function M.reset()
  checked, available = {}, {}
end

return M
