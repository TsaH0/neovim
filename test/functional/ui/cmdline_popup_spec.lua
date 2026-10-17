-- Tests for 'cmdlinepopup' (runtime/lua/vim/_core/cmdline_popup.lua).

local t = require('test.testutil')
local n = require('test.functional.testnvim')()
local Screen = require('test.functional.ui.screen')

local describe, it, before_each = t.describe, t.it, t.before_each
local eq = t.eq
local feed = n.feed

--- Text and title of the popup window ({} when hidden).
local function popup()
  return n.exec_lua(function()
    local p = require('vim._core.cmdline_popup')
    if not vim.api.nvim_win_is_valid(p.win) or vim.api.nvim_win_get_config(p.win).hide then
      return {}
    end
    local title = vim.api.nvim_win_get_config(p.win).title[1][1]
    return { title, vim.api.nvim_buf_get_lines(p.buf, 0, -1, false) }
  end)
end

describe("'cmdlinepopup'", function()
  local screen
  before_each(function()
    n.clear()
    screen = Screen.new(50, 10)
    n.command('set cmdlinepopup')
  end)

  it('shows ":" in a titled floating window', function()
    feed(':echo "hi"')
    screen:expect({ any = { 'Cmdline', '╭', '╰' } })
    eq({ ' Cmdline ', { '> echo "hi"' } }, popup())
    feed('<CR>')
    screen:expect({ any = { 'hi' }, none = { 'Cmdline' } })
    eq({}, popup())
  end)

  it('titles search and input() prompts', function()
    feed('/foo')
    screen:expect({ any = { 'Search' } })
    eq({ ' Search ', { '/ foo' } }, popup())
    feed('<Esc>')
    feed(':call input("select: ")<CR>ab')
    screen:expect({ any = { 'Select' } })
    eq({ ' Select ', { '> ab' } }, popup())
    feed('<Esc>')
  end)

  it('runs commands, keeps history; can be turned off', function()
    feed(':let g:x = 42<CR>')
    eq(42, n.eval('g:x'))
    feed(':<Up>')
    screen:expect({ any = { 'Cmdline' } })
    eq({ ' Cmdline ', { '> let g:x = 42' } }, popup())
    feed('<Esc>')
    feed(':set nocmdlinepopup<CR>:')
    screen:expect({ none = { 'Cmdline' }, any = { ':%^' } })
    eq(false, n.exec_lua('return require("vim._core.cmdline_popup").enabled'))
    feed('<Esc>')
  end)
end)
