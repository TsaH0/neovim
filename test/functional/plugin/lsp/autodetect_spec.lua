-- Tests for 'lspautodetect' (runtime/lua/vim/_core/lsp_detect.lua).

local t = require('test.testutil')
local n = require('test.functional.testnvim')()
local t_lsp = require('test.functional.plugin.lsp.testutil')

local describe, it, before_each = t.describe, t.it, t.before_each
local eq = t.eq
local exec_lua = n.exec_lua

describe("'lspautodetect'", function()
  before_each(function()
    n.clear()
    n.command('filetype on')
    exec_lua(t_lsp.create_server_definition)
    exec_lua(function()
      -- In-process servers: a `cmd` function counts as installed.
      local function fake()
        return _G._create_server({ capabilities = { hoverProvider = true } }).cmd
      end
      vim.lsp.config('lua_ls', { cmd = fake() })
      vim.lsp.config('basedpyright', { cmd = { 'nonexistent-basedpyright-xyz' } })
      vim.lsp.config('pyright', { cmd = { 'nonexistent-pyright-xyz' } })
      vim.lsp.config('pylsp', { cmd = fake() })
      vim.lsp.config('ruff', { cmd = { 'nonexistent-ruff-xyz' } })
      vim.lsp.config('rust_analyzer', { cmd = { 'nonexistent-ra-xyz' } })
      vim.o.lspautodetect = true
    end)
  end)

  it('enables installed servers for the filetype and attaches', function()
    n.command('edit ' .. t.tmpname() .. '.lua')
    eq('lua', exec_lua('return vim.bo.filetype'))
    eq(true, exec_lua('return vim.lsp.is_enabled("lua_ls")'))
    t.retry(nil, 2000, function()
      eq({ 'lua_ls' }, exec_lua(function()
        return vim.tbl_map(function(c)
          return c.name
        end, vim.lsp.get_clients({ bufnr = 0 }))
      end))
    end)
  end)

  it('picks the first installed alternative', function()
    n.command('edit ' .. t.tmpname() .. '.py')
    eq(false, exec_lua('return vim.lsp.is_enabled("basedpyright")'))
    eq(false, exec_lua('return vim.lsp.is_enabled("pyright")'))
    eq(true, exec_lua('return vim.lsp.is_enabled("pylsp")'))
    eq(false, exec_lua('return vim.lsp.is_enabled("ruff")'))
  end)

  it('skips servers that are not installed', function()
    n.command('edit ' .. t.tmpname() .. '.rs')
    eq('rust', exec_lua('return vim.bo.filetype'))
    eq(false, exec_lua('return vim.lsp.is_enabled("rust_analyzer")'))
  end)

  it('does nothing when off', function()
    n.command('set nolspautodetect')
    n.command('edit ' .. t.tmpname() .. '.lua')
    eq(false, exec_lua('return vim.lsp.is_enabled("lua_ls")'))
  end)

  it('ships default configs for the known servers', function()
    local missing = exec_lua(function()
      local out = {}
      for _, groups in pairs(require('vim._core.lsp_detect').servers) do
        for _, group in ipairs(groups) do
          for _, name in ipairs(group) do
            if #vim.api.nvim_get_runtime_file('lsp/' .. name .. '.lua', false) == 0 then
              out[#out + 1] = name
            end
          end
        end
      end
      return out
    end)
    eq({}, missing)
  end)
end)
