--- @brief
--- Helix keymap and selection model for Nvim. See |helix-mode|.
---
--- Every Helix command is implemented as a function in `M.commands`, named
--- like the Helix command (`move_next_word_start`, `select_regex`, …), and
--- bound to the Helix default keys by |M.enable()| (see 'helix').

local api, fn = vim.api, vim.fn
local sel = require('vim._core.helix_sel')

local M = {}

M.enabled = false

---@type table<string, {fn: fun(), desc: string, keys?: string}>
M.commands = {}
local C = {} ---@type table<string, fun()>

---@param name string
---@param desc string
---@param f fun()
local function cmd(name, desc, f)
  M.commands[name] = { fn = f, desc = desc }
  C[name] = f
end

local function count()
  return vim.v.count1
end

local function has_count()
  return vim.v.count > 0
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO)
end

--- Reads one key. Returns nil on <Esc>/<C-c>.
---@return string?
local function getkey()
  local ok, k = pcall(fn.getcharstr)
  if not ok or k == '\27' or k == '\3' then
    return nil
  end
  return k
end

-- Registers {{{

--- Register selected by `"<reg>` for the next command.
---@type string?
M.reg_pending = nil

---@type table<string, {vals: string[], vimtext?: string}>
local regs = {}

---@param default? string
---@return string
local function take_reg(default)
  local r = M.reg_pending
  M.reg_pending = nil
  return r or default or '"'
end

--- Vim register backing Helix register `r`.
local function vimreg(r)
  if r == '"' or r:match('^[%w%-%+%*]$') then
    return r
  end
end

---@param r string
---@param vals string[]
local function reg_write(r, vals)
  if r == '_' then
    return
  end
  local vr = vimreg(r)
  local entry = { vals = vals }
  if vr then
    local linewise = #vals > 0
    for _, v in ipairs(vals) do
      if v:sub(-1) ~= '\n' then
        linewise = false
      end
    end
    local text = linewise and table.concat(vals) or table.concat(vals, '\n')
    pcall(fn.setreg, vr, text, linewise and 'l' or 'c')
    local ok, got = pcall(fn.getreg, vr)
    entry.vimtext = ok and got or nil
  end
  regs[r] = entry
end

---@param r string
---@return string[]
local function reg_read(r)
  if r == '_' then
    return {}
  elseif r == '#' then
    local out = {}
    for i = 1, #sel.get().sels do
      out[i] = tostring(i)
    end
    return out
  elseif r == '.' then
    return vim.tbl_map(sel.text, sel.get().sels)
  elseif r == '%' then
    return { fn.expand('%') }
  end
  local vr = vimreg(r)
  local entry = regs[r]
  if vr then
    local ok, text = pcall(fn.getreg, vr)
    if ok and entry and entry.vimtext == text then
      return entry.vals
    end
    if ok and text ~= '' then
      local rt = fn.getregtype(vr)
      if rt == 'V' and text:sub(-1) ~= '\n' then
        text = text .. '\n'
      end
      return { text }
    end
  end
  return entry and entry.vals or {}
end

-- }}}

-- Regex {{{

--- Converts a Helix (Rust/PCRE-style) regex to a Vim regex.
---@param pat string
---@return string
function M.regex(pat)
  if pat:match('^\\[vVmMcC]') then
    return pat -- Already a Vim pattern.
  end
  local out = { '\\v' }
  local i, n = 1, #pat
  local function lazy()
    if pat:sub(i + 1, i + 1) == '?' then
      i = i + 1
      return true
    end
  end
  while i <= n do
    local c = pat:sub(i, i)
    if c == '\\' then
      local d = pat:sub(i + 1, i + 1)
      i = i + 1
      if d == 'b' then
        out[#out + 1] = '%(<|>)'
      elseif d == 'A' then
        out[#out + 1] = '%^'
      elseif d == 'z' then
        out[#out + 1] = '%$'
      else
        out[#out + 1] = '\\' .. d
      end
    elseif c:match('[<>=@%%&~]') then
      out[#out + 1] = '\\' .. c
    elseif c == '(' and pat:sub(i + 1, i + 2) == '?:' then
      out[#out + 1] = '%('
      i = i + 2
    elseif c == '(' and pat:sub(i + 1, i + 3) == '?i)' then
      out[#out + 1] = '\\c'
      i = i + 3
    elseif c == '*' then
      out[#out + 1] = lazy() and '{-}' or '*'
    elseif c == '+' then
      out[#out + 1] = lazy() and '{-1,}' or '+'
    elseif c == '?' then
      out[#out + 1] = lazy() and '{-0,1}' or '?'
    elseif c == '{' then
      local q = pat:match('^{[%d,]*}', i)
      if q then
        i = i + #q - 1
        out[#out + 1] = lazy() and ('{-' .. q:sub(2)) or q
      else
        out[#out + 1] = '\\{'
      end
    elseif c == '[' then
      -- Copy a character class verbatim.
      local j = i + 1
      if pat:sub(j, j) == '^' then
        j = j + 1
      end
      if pat:sub(j, j) == ']' then
        j = j + 1
      end
      while j <= n and pat:sub(j, j) ~= ']' do
        if pat:sub(j, j) == '\\' then
          j = j + 1
        end
        j = j + 1
      end
      out[#out + 1] = pat:sub(i, j)
      i = j
    else
      out[#out + 1] = c
    end
    i = i + 1
  end
  local p = table.concat(out)
  -- Smart case, like Helix.
  if not pat:match('%u') and not p:find('\\c', 1, true) then
    p = '\\c' .. p
  end
  return p
end

--- Compiles a Vim pattern; nil on error.
---@param vpat string
---@return vim.regex?
local function compile(vpat)
  local ok, re = pcall(vim.regex, vpat)
  return ok and re or nil
end

--- All matches of `re` inside selection `s`.
---@param re vim.regex
---@param s nvim.helix.Sel
---@return nvim.helix.Sel[]
local function matches_in(re, s)
  local f, t = sel.from(s), sel.to(s)
  local e = sel.after(t)
  local out = {}
  for row = f[1], math.min(e[1], sel.line_count() - 1) do
    local l = sel.line(row)
    local col = row == f[1] and f[2] or 0
    local stop = row == e[1] and math.min(e[2], #l) or #l
    if row == e[1] and e[2] == 0 and row ~= f[1] then
      break
    end
    while col <= stop do
      local ms, me = re:match_line(0, row, col, stop)
      if not ms then
        break
      end
      local a, b = col + ms, col + me
      if b > a then
        out[#out + 1] = { a = { row, a }, h = sel.prev({ row, b }) or { row, a } }
        col = b
      else
        col = a + 1
      end
    end
  end
  return out
end

--- Finds the next match of `vpat` after (or before) `p`, wrapping.
---@param vpat string
---@param p nvim.helix.Pos
---@param backward? boolean
---@return nvim.helix.Sel?, boolean? wrapped
local function find(vpat, p, backward)
  local view = fn.winsaveview()
  pcall(api.nvim_win_set_cursor, 0, { p[1] + 1, p[2] })
  local ok, s = pcall(fn.searchpos, vpat, backward and 'bnw' or 'nw')
  local res, wrapped
  if ok and s[1] > 0 then
    local a = { s[1] - 1, s[2] - 1 }
    api.nvim_win_set_cursor(0, { s[1], s[2] - 1 })
    local e = fn.searchpos(vpat, 'cenW')
    local h = e[1] > 0 and { e[1] - 1, e[2] - 1 } or a
    if sel.cmp(h, a) < 0 then
      h = a
    end
    res = { a = a, h = h }
    local c = sel.cmp(a, p)
    wrapped = (backward and c > 0) or (not backward and c <= 0)
  end
  fn.winrestview(view)
  return res, wrapped
end

-- }}}

-- Prompt with live preview {{{

--- Prompts for input, calling `preview(text)` as the user types. Selections
--- are restored if the prompt is cancelled.
---@param label string
---@param preview? fun(text: string)
---@param default? string
---@return string?
local function prompt(label, preview, default)
  local st = sel.get()
  local saved, saved_p = vim.deepcopy(st.sels), st.primary
  local view = fn.winsaveview()
  local au ---@type integer?
  if preview then
    au = api.nvim_create_autocmd('CmdlineChanged', {
      callback = function()
        if fn.getcmdtype() ~= '@' then
          return
        end
        local text = fn.getcmdline()
        st.sels, st.primary = vim.deepcopy(saved), saved_p
        if text ~= '' then
          pcall(preview, text)
        else
          sel.set(vim.deepcopy(saved), saved_p)
        end
        vim.cmd.redraw()
      end,
    })
  end
  local ok, text = pcall(fn.input, { prompt = label, default = default or '', cancelreturn = '\0' })
  if au then
    api.nvim_del_autocmd(au)
  end
  st.sels, st.primary = saved, saved_p
  api.nvim_echo({}, false, {})
  if not ok or text == '\0' then
    fn.winrestview(view)
    sel.set(vim.deepcopy(saved), saved_p)
    return nil
  end
  sel.set(vim.deepcopy(saved), saved_p)
  return text
end

-- }}}

-- Motions {{{

--- Applies `f` to each selection. `f` returns a new position (collapsing the
--- selection), a new selection, or nil (unchanged). In select mode the anchor
--- is kept.
---@param f fun(s: nvim.helix.Sel, i: integer): (nvim.helix.Pos|nvim.helix.Sel|nil)
local function motion(f)
  local st = sel.get()
  local new = {}
  for i, s in ipairs(st.sels) do
    local r = f(vim.deepcopy(s), i)
    if r == nil then
      r = s
    elseif r.a == nil then
      r = { a = r, h = vim.deepcopy(r), want = r.want }
    end
    if M.mode == 'select' then
      r = { a = s.a, h = r.h, want = r.want }
    end
    new[i] = r
  end
  sel.set(new, st.primary)
end

--- Pushes the current position to the jumplist.
local function push_jump()
  sel.sync_cursor()
  vim.cmd("normal! m'")
end

local function C_(q, long)
  return sel.class(sel.char(q), long)
end

--- `w`/`W`: next word start.
local function word_next_start(p, long)
  local n = sel.next(p)
  if not n then
    return nil
  end
  local start = p
  if C_(p, long) ~= C_(n, long) then
    start = n
  end
  while C_(start, long) == 'eol' do
    local q = sel.next(start)
    if not q then
      break
    end
    start = q
  end
  local h = start
  while true do
    local q = sel.next(h)
    if not q then
      break
    end
    local cq, ch = C_(q, long), C_(h, long)
    if cq == 'eol' or (cq ~= ch and cq ~= 'ws') then
      break
    end
    h = q
  end
  return { a = start, h = h }
end

--- `e`/`E`: next word end.
local function word_next_end(p, long)
  local n = sel.next(p)
  if not n then
    return nil
  end
  local start = p
  if C_(p, long) ~= C_(n, long) then
    start = n
  end
  while C_(start, long) == 'eol' do
    local q = sel.next(start)
    if not q then
      break
    end
    start = q
  end
  local h = start
  while C_(h, long) == 'ws' do
    local q = sel.next(h)
    if not q or C_(q, long) == 'eol' then
      break
    end
    h = q
  end
  while true do
    local q = sel.next(h)
    if not q or C_(q, long) ~= C_(h, long) then
      break
    end
    h = q
  end
  return { a = start, h = h }
end

--- `b`/`B`: previous word start.
local function word_prev_start(p, long)
  local q0 = sel.prev(p)
  if not q0 then
    return nil
  end
  local start = p
  if C_(p, long) ~= C_(q0, long) then
    start = q0
  end
  while C_(start, long) == 'eol' do
    local q = sel.prev(start)
    if not q then
      break
    end
    start = q
  end
  local h = start
  while C_(h, long) == 'ws' do
    local q = sel.prev(h)
    if not q or C_(q, long) == 'eol' then
      break
    end
    h = q
  end
  while true do
    local q = sel.prev(h)
    if not q or C_(q, long) ~= C_(h, long) then
      break
    end
    h = q
  end
  return { a = start, h = h }
end

local function word_motion(f, long)
  local n = count()
  motion(function(s)
    local r
    local p = s.h
    for _ = 1, n do
      local nr = f(p, long)
      if not nr then
        break
      end
      r, p = nr, nr.h
    end
    return r
  end)
end

cmd('move_next_word_start', 'Move to start of next word', function()
  word_motion(word_next_start, false)
end)
cmd('move_prev_word_start', 'Move to start of previous word', function()
  word_motion(word_prev_start, false)
end)
cmd('move_next_word_end', 'Move to end of next word', function()
  word_motion(word_next_end, false)
end)
cmd('move_next_long_word_start', 'Move to start of next WORD', function()
  word_motion(word_next_start, true)
end)
cmd('move_prev_long_word_start', 'Move to start of previous WORD', function()
  word_motion(word_prev_start, true)
end)
cmd('move_next_long_word_end', 'Move to end of next WORD', function()
  word_motion(word_next_end, true)
end)

cmd('move_char_left', 'Move left', function()
  local n = count()
  motion(function(s)
    local p = s.h
    for _ = 1, n do
      if p[2] == 0 then
        break
      end
      p = sel.prev(p) or p
    end
    return p
  end)
end)

cmd('move_char_right', 'Move right', function()
  local n = count()
  motion(function(s)
    local p = s.h
    for _ = 1, n do
      if p[2] >= #sel.line(p[1]) then
        break
      end
      p = sel.next(p) or p
    end
    return p
  end)
end)

--- Display column (0-based) of the char at `p`.
local function vcol(p)
  return fn.strdisplaywidth(sel.line(p[1]):sub(1, p[2]))
end

--- Byte col of the char covering display column `want` on row `r`.
local function col_at_vcol(r, want)
  local l = sel.line(r)
  local w, c = 0, 0
  while c < #l do
    local len = sel.charlen(l, c)
    local cw = fn.strdisplaywidth(l:sub(c + 1, c + len), w)
    if w + cw > want then
      return c
    end
    w, c = w + cw, c + len
  end
  return #l
end

local function vertical(dir)
  local n = count()
  local lc = sel.line_count()
  motion(function(s)
    local want = s.want or vcol(s.h)
    local r = math.max(0, math.min(lc - 1, s.h[1] + dir * n))
    local p = { r, col_at_vcol(r, want) }
    return { a = p, h = p, want = want }
  end)
end

cmd('move_visual_line_down', 'Move down', function()
  vertical(1)
end)
cmd('move_visual_line_up', 'Move up', function()
  vertical(-1)
end)
cmd('move_line_down', 'Move down textual line', function()
  vertical(1)
end)
cmd('move_line_up', 'Move up textual line', function()
  vertical(-1)
end)

--- Last f/t/F/T (or other repeatable) motion, for Alt-.
---@type fun()?
local last_motion

--- Finds `ch` forward/backward from `p` (across lines).
---@return nvim.helix.Pos?
local function find_char(p, ch, forward, n)
  local lc = sel.line_count()
  local r, c = p[1], p[2]
  local l = sel.line(r)
  if forward then
    c = c + sel.charlen(l, c) -- Start after the current char.
    while r < lc do
      l = sel.line(r)
      if ch == '\n' then
        if c <= #l then
          n = n - 1
          if n == 0 then
            return { r, #l }
          end
        end
      else
        local i = l:find(ch, c + 1, true)
        while i do
          n = n - 1
          if n == 0 then
            return { r, i - 1 }
          end
          i = l:find(ch, i + #ch, true)
        end
      end
      r, c = r + 1, 0
    end
  else
    while r >= 0 do
      l = sel.line(r)
      if ch == '\n' then
        if r ~= p[1] then
          n = n - 1
          if n == 0 then
            return { r, #l }
          end
        end
      else
        local last = {}
        local i = l:find(ch, 1, true)
        while i and i - 1 < c do
          last[#last + 1] = i - 1
          i = l:find(ch, i + #ch, true)
        end
        for j = #last, 1, -1 do
          n = n - 1
          if n == 0 then
            return { r, last[j] }
          end
        end
      end
      r = r - 1
      c = r >= 0 and #sel.line(r) + 1 or 0
    end
  end
end

local last_find ---@type string?

local function find_motion(forward, till, ch, n)
  local key = tostring(forward) .. tostring(till) .. ch
  local repeated = last_find == key
  last_find = key
  local function run()
    motion(function(s)
      local start = s.h
      local anchor = s.h
      if till and repeated then
        -- Skip the adjacent char so repeated `t` makes progress.
        local adj = forward and sel.next(start) or sel.prev(start)
        if adj and sel.char(adj) == ch then
          start, anchor = adj, adj
        end
      end
      local p = find_char(start, ch, forward, n)
      if not p then
        return nil
      end
      if till then
        p = (forward and sel.prev(p) or sel.next(p)) or p
      end
      return { a = anchor, h = p }
    end)
  end
  last_motion = function()
    repeated = true
    run()
  end
  run()
end

local function find_cmd(forward, till)
  return function()
    local n = count()
    local k = getkey()
    if not k then
      return
    end
    if k == '\r' then
      k = '\n'
    end
    find_motion(forward, till, k, n)
  end
end

cmd('find_till_char', 'Move till next occurrence of char', find_cmd(true, true))
cmd('find_next_char', 'Move to next occurrence of char', find_cmd(true, false))
cmd('till_prev_char', 'Move till previous occurrence of char', find_cmd(false, true))
cmd('find_prev_char', 'Move to previous occurrence of char', find_cmd(false, false))

cmd('repeat_last_motion', 'Repeat last motion', function()
  if last_motion then
    last_motion()
  end
end)

local function goto_pos(p)
  motion(function()
    return sel.clamp(p)
  end)
end

local function first_nonblank(r)
  local l = sel.line(r)
  return (l:find('%S') or (#l + 1)) - 1
end

cmd('goto_line', 'Goto line', function()
  if has_count() then
    local r = math.min(vim.v.count, sel.line_count()) - 1
    push_jump()
    goto_pos({ r, first_nonblank(r) })
  end
end)

cmd('goto_file_start', 'Goto line number <n> else file start', function()
  local c = vim.v.count
  push_jump()
  if c > 0 then
    local r = math.min(c, sel.line_count()) - 1
    goto_pos({ r, first_nonblank(r) })
  else
    goto_pos({ 0, 0 })
  end
end)

cmd('goto_last_line', 'Goto last line', function()
  push_jump()
  goto_pos({ sel.line_count() - 1, 0 })
end)

cmd('goto_line_start', 'Goto line start', function()
  motion(function(s)
    return { s.h[1], 0 }
  end)
end)

cmd('goto_line_end', 'Goto line end', function()
  motion(function(s)
    local l = sel.line(s.h[1])
    return sel.clamp({ s.h[1], math.max(0, #l - 1) })
  end)
end)

cmd('goto_line_end_newline', 'Goto newline at line end', function()
  motion(function(s)
    return { s.h[1], #sel.line(s.h[1]) }
  end)
end)

cmd('goto_first_nonwhitespace', 'Goto first non-blank in line', function()
  motion(function(s)
    return { s.h[1], first_nonblank(s.h[1]) }
  end)
end)

cmd('goto_column', 'Goto column', function()
  local n = count()
  motion(function(s)
    return sel.clamp({ s.h[1], col_at_vcol(s.h[1], n - 1) })
  end)
end)

local function window_row(which)
  local top, bot = fn.line('w0') - 1, fn.line('w$') - 1
  local so = math.min(vim.wo.scrolloff, math.floor((bot - top) / 2))
  if which == 'top' then
    return top == 0 and 0 or top + so
  elseif which == 'bottom' then
    return bot == sel.line_count() - 1 and bot or bot - so
  end
  return math.floor((top + bot) / 2)
end

for _, w in ipairs({ 'top', 'center', 'bottom' }) do
  cmd('goto_window_' .. w, 'Goto window ' .. w, function()
    local r = window_row(w)
    goto_pos({ r, first_nonblank(r) })
  end)
end

--- Runs a native Normal-mode command from the primary head and moves the
--- head (or collapses) to the resulting cursor.
local function native(keys)
  local st = sel.get()
  local before = vim.deepcopy(st.sels[st.primary])
  sel.sync_cursor()
  sel.busy = true
  local ok, err = pcall(vim.cmd, 'normal! ' .. vim.keycode(keys))
  sel.busy = false
  if not ok then
    notify(tostring(err):gsub('^Vim%(normal%):', ''), vim.log.levels.ERROR)
  end
  local c = api.nvim_win_get_cursor(0)
  local p = sel.clamp({ c[1] - 1, c[2] })
  if M.mode == 'select' then
    sel.set({ { a = before.a, h = p } })
  else
    sel.set({ { a = p, h = p } })
  end
end

cmd('page_up', 'Move page up', function()
  native(count() .. '<C-b>')
end)
cmd('page_down', 'Move page down', function()
  native(count() .. '<C-f>')
end)
--- Scrolls an open LSP popup (hover/signature), like Helix. Returns true
--- if there was one.
local function scroll_popup(key)
  local win = vim.b.lsp_floating_preview
  if not win or not api.nvim_win_is_valid(win) then
    return false
  end
  api.nvim_win_call(win, function()
    vim.cmd('normal! ' .. vim.keycode(key))
  end)
  return true
end

cmd('page_cursor_half_up', 'Move page and cursor half up', function()
  if not scroll_popup('<C-u>') then
    native('<C-u>')
  end
end)
cmd('page_cursor_half_down', 'Move page and cursor half down', function()
  if not scroll_popup('<C-d>') then
    native('<C-d>')
  end
end)

local function jump(key)
  sel.sync_cursor()
  local ok, err = pcall(vim.cmd, 'normal! ' .. count() .. vim.keycode(key))
  if not ok then
    notify(tostring(err):gsub('^Vim%(normal%):', ''), vim.log.levels.WARN)
  end
  sel.reset_to_cursor()
end

cmd('jump_forward', 'Jump forward on jumplist', function()
  jump('<C-i>')
end)
cmd('jump_backward', 'Jump backward on jumplist', function()
  jump('<C-o>')
end)
cmd('save_selection', 'Save current selection to jumplist', function()
  push_jump()
  notify('Selection saved to jumplist')
end)

-- }}}

-- Insert mode {{{

---@class nvim.helix.InsertState
---@field kind string
---@field items {a: integer, h: integer, p: integer, f: integer, p0: nvim.helix.Pos}[]
---@field primary integer
---@field buf integer

---@type nvim.helix.InsertState?
local ins = nil

--- Last insert, for `.`.
---@type {kind: string, keys: string}?
local last_insert = nil
local recording_keys = nil ---@type string[]?
local replaying = false

--- Enters Insert mode at each selection. `kind` is one of
--- i, a, I, A, o, O, c.
---@param kind string
local function enter_insert(kind)
  local st = sel.get()
  local items = {}
  local points = {} ---@type nvim.helix.Pos[]
  for i, s in ipairs(st.sels) do
    local f, t = sel.from(s), sel.to(s)
    local p ---@type nvim.helix.Pos
    if kind == 'i' or kind == 'c' then
      p = f
    elseif kind == 'a' then
      p = sel.after(t)
      if sel.cmp(p, t) == 0 then
        p = { t[1], #sel.line(t[1]) }
      end
    elseif kind == 'I' then
      p = { f[1], first_nonblank(f[1]) }
    elseif kind == 'A' or kind == 'o' then
      p = { t[1], #sel.line(t[1]) }
    elseif kind == 'O' then
      p = { f[1], 0 }
    end
    points[i] = p
    items[i] = {
      a = sel.mark(s.a),
      h = sel.mark(s.h),
      f = sel.mark(f, false),
      p = sel.mark(p),
      p0 = p,
    }
  end
  ins = { kind = kind, items = items, primary = st.primary, buf = api.nvim_get_current_buf() }
  if not replaying then
    recording_keys = {}
  end
  -- Primary at its insert point; extra cursors at the others.
  local pp = points[st.primary]
  sel.busy = true
  api.nvim_win_set_cursor(0, { pp[1] + 1, pp[2] })
  sel.busy = false
  local seen = { [pp[1] .. ':' .. pp[2]] = true }
  api.nvim_buf_clear_namespace(0, sel.mc_ns, 0, -1)
  for i, p in ipairs(points) do
    local key = (kind == 'o' or kind == 'O') and tostring(p[1]) or (p[1] .. ':' .. p[2])
    if i ~= st.primary and not seen[key] and not (kind:match('[oO]') and p[1] == pp[1]) then
      seen[key] = true
      api.nvim_buf_set_extmark(0, sel.mc_ns, p[1], p[2], {})
    end
  end
  api.nvim_buf_clear_namespace(0, sel.ns, 0, -1)
  local key = (kind == 'o' or kind == 'O') and kind or 'i'
  api.nvim_feedkeys(key, 'ni', false)
end

--- Insert session that ended but whose selections aren't rebuilt yet: the
--- multicursor commits mirrored text after InsertLeave.
---@type nvim.helix.InsertState?
local leaving = nil

--- Rebuilds the selections after leaving Insert mode.
local function finish_insert()
  local state = leaving
  leaving = nil
  if not state then
    return
  end
  if api.nvim_get_current_buf() ~= state.buf then
    pcall(api.nvim_buf_clear_namespace, state.buf, sel.mc_ns, 0, -1)
    pcall(api.nvim_buf_clear_namespace, state.buf, sel.track_ns, 0, -1)
    return
  end
  api.nvim_buf_clear_namespace(0, sel.mc_ns, 0, -1)
  local new = {}
  for i, it in ipairs(state.items) do
    local a, h, f, p = sel.unmark(it.a), sel.unmark(it.h), sel.unmark(it.f), sel.unmark(it.p)
    local typed = sel.cmp(p, it.p0) ~= 0
    local k = state.kind
    if k == 'i' then
      new[i] = { a = a, h = h }
    elseif k == 'a' then
      local hh = sel.prev(p) or p
      if sel.cmp(hh, f) < 0 then
        hh = f
      end
      new[i] = { a = f, h = hh }
    elseif k == 'o' or k == 'O' then
      local r = k == 'o' and math.min(p[1] + 1, sel.line_count() - 1) or math.max(0, p[1] - 1)
      local l = sel.line(r)
      local c = #l > 0 and (sel.prev({ r, #l }) or { r, 0 })[2] or 0
      new[i] = { a = { r, c }, h = { r, c } }
    else
      local hh = typed and (sel.prev(p) or p) or p
      new[i] = { a = hh, h = hh }
    end
  end
  if recording_keys and not replaying then
    last_insert = { kind = state.kind, keys = table.concat(recording_keys) }
  end
  recording_keys = nil
  sel.set(new, state.primary)
end

local insert_ns = api.nvim_create_namespace('nvim.helix.insert_keys')

cmd('insert_mode', 'Insert before selection', function()
  enter_insert('i')
end)
cmd('append_mode', 'Append after selection', function()
  enter_insert('a')
end)
cmd('insert_at_line_start', 'Insert at start of line', function()
  enter_insert('I')
end)
cmd('insert_at_line_end', 'Insert at end of line', function()
  enter_insert('A')
end)
cmd('open_below', 'Open new line below selection', function()
  enter_insert('o')
end)
cmd('open_above', 'Open new line above selection', function()
  enter_insert('O')
end)

-- }}}

-- Changes {{{

local function yank_vals(r)
  local vals = vim.tbl_map(sel.text, sel.get().sels)
  reg_write(r, vals)
  return vals
end

cmd('yank', 'Yank selection', function()
  local r = take_reg()
  local vals = yank_vals(r)
  if r ~= '_' then
    notify(('yanked %d selection%s to register %s'):format(#vals, #vals == 1 and '' or 's', r))
  end
end)

local function delete(yank)
  local r = take_reg()
  if yank then
    yank_vals(r)
  end
  sel.transform(function(s)
    local p = sel.delete(s)
    return { a = p, h = p }
  end)
end

cmd('delete_selection', 'Delete selection', function()
  delete(true)
end)
cmd('delete_selection_noyank', 'Delete selection without yanking', function()
  delete(false)
end)

local function change(yank)
  local r = take_reg()
  if yank then
    yank_vals(r)
  end
  sel.transform(function(s)
    local f, t = sel.from(s), sel.to(s)
    local linewise = f[2] == 0 and t[2] >= #sel.line(t[1])
    if linewise and sel.cmp(f, t) ~= 0 then
      -- Keep the final newline: changing whole lines leaves an empty line.
      local l = sel.line(t[1])
      if t[1] > f[1] or #l > 0 then
        api.nvim_buf_set_text(0, f[1], 0, t[1], #l, { '' })
      end
      return { a = f, h = f }
    end
    local p = sel.delete(s)
    return { a = p, h = p }
  end)
  enter_insert('c')
end

cmd('change_selection', 'Change selection', function()
  change(true)
end)
cmd('change_selection_noyank', 'Change selection without yanking', function()
  change(false)
end)

local function paste(before, r)
  local vals = reg_read(r)
  if #vals == 0 then
    notify(('register %s is empty'):format(r), vim.log.levels.WARN)
    return
  end
  local n = count()
  sel.transform(function(s, i)
    local v = vals[math.min(i, #vals)]
    local text = v:rep(n)
    local f, t = sel.from(s), sel.to(s)
    local p ---@type nvim.helix.Pos
    if text:sub(-1) == '\n' then
      -- Linewise.
      if before then
        p = { f[1], 0 }
      else
        if t[1] + 1 >= sel.line_count() then
          local last = sel.line_count() - 1
          local e = sel.insert({ last, #sel.line(last) }, '\n' .. text:sub(1, -2))
          return { a = { last + 1, 0 }, h = { e[1], #sel.line(e[1]) } }
        end
        p = { t[1] + 1, 0 }
      end
      local e = sel.insert(p, text)
      return { a = p, h = e }
    end
    p = before and f or sel.after(t)
    if not before and sel.cmp(p, t) == 0 then
      p = { t[1], #sel.line(t[1]) }
    end
    local e = sel.insert(p, text)
    return { a = p, h = e }
  end)
end

cmd('paste_after', 'Paste after selection', function()
  paste(false, take_reg())
end)
cmd('paste_before', 'Paste before selection', function()
  paste(true, take_reg())
end)

local function replace_with(r)
  local vals = reg_read(r)
  if #vals == 0 then
    notify(('register %s is empty'):format(r), vim.log.levels.WARN)
    return
  end
  local n = count()
  sel.transform(function(s, i)
    return sel.replace(s, vals[math.min(i, #vals)]:rep(n))
  end)
end

cmd('replace_with_yanked', 'Replace with yanked text', function()
  replace_with(take_reg())
end)

local utf8_char = '[%z\1-\127\194-\244][\128-\191]*'

---@param f fun(c: string): string
local function map_chars(f)
  sel.transform(function(s)
    local text = sel.text(s)
    local new = text:gsub(utf8_char, function(c)
      return c == '\n' and c or f(c)
    end)
    if new == text then
      return s
    end
    return sel.replace(s, new)
  end)
end

cmd('replace', 'Replace with new char', function()
  local k = getkey()
  if not k then
    return
  end
  if k == '\r' then
    sel.transform(function(s)
      return sel.replace(s, (sel.text(s):gsub('[^\n]+', '\n')))
    end)
    return
  end
  map_chars(function()
    return k
  end)
end)

cmd('switch_case', 'Switch (toggle) case', function()
  map_chars(function(c)
    local u = fn.toupper(c)
    if u ~= c then
      return u
    end
    return fn.tolower(c)
  end)
end)
cmd('switch_to_lowercase', 'Switch to lowercase', function()
  map_chars(fn.tolower)
end)
cmd('switch_to_uppercase', 'Switch to uppercase', function()
  map_chars(fn.toupper)
end)

cmd('repeat_last_insert', 'Repeat last insert', function()
  if not last_insert then
    return
  end
  replaying = true
  api.nvim_feedkeys(last_insert.keys .. '\27', 'ni', false)
  enter_insert(last_insert.kind)
  vim.schedule(function()
    replaying = false
  end)
end)

local function undo_cmd(ex)
  local n = count()
  sel.busy = true
  for _ = 1, n do
    local ok, err = pcall(vim.cmd, 'silent ' .. ex)
    if not ok then
      notify(tostring(err), vim.log.levels.WARN)
      break
    end
  end
  sel.busy = false
  sel.reset_to_cursor()
end

cmd('undo', 'Undo change', function()
  undo_cmd('undo')
end)
cmd('redo', 'Redo change', function()
  undo_cmd('redo')
end)
cmd('earlier', 'Move backward in history', function()
  undo_cmd('earlier')
end)
cmd('later', 'Move forward in history', function()
  undo_cmd('later')
end)

--- Rows covered by the selections, as sorted disjoint [r1, r2] ranges.
local function line_ranges()
  local ranges = {}
  for _, s in ipairs(sel.get().sels) do
    local f, t = sel.from(s), sel.to(s)
    local r2 = t[1]
    local last = ranges[#ranges]
    if last and f[1] <= last[2] then
      last[2] = math.max(last[2], r2)
    else
      ranges[#ranges + 1] = { f[1], r2 }
    end
  end
  return ranges
end

local function indent(dir)
  local n = count()
  sel.track(function()
    for i = #line_ranges(), 1, -1 do
      local r = line_ranges()[i]
      vim.cmd(('silent %d,%d%s'):format(r[1] + 1, r[2] + 1, dir:rep(n)))
    end
  end)
end

cmd('indent', 'Indent selection', function()
  indent('>')
end)
cmd('unindent', 'Unindent selection', function()
  indent('<')
end)

cmd('format_selections', 'Format selection', function()
  local clients = vim.lsp.get_clients({ bufnr = 0, method = 'textDocument/rangeFormatting' })
  if #clients > 0 then
    sel.track(function()
      for _, s in ipairs(sel.get().sels) do
        local f, t = sel.from(s), sel.to(s)
        vim.lsp.buf.format({
          async = false,
          range = { start = { f[1] + 1, f[2] }, ['end'] = { t[1] + 1, t[2] } },
        })
      end
    end)
    return
  end
  sel.track(function()
    for _, r in ipairs(line_ranges()) do
      M.internal_visual = true
      vim.cmd(('silent normal! %dGV%dG='):format(r[1] + 1, r[2] + 1))
      M.internal_visual = false
    end
  end)
end)

cmd('increment', 'Increment item under cursor', function()
  local n = count()
  sel.transform(function(s)
    local f = sel.from(s)
    api.nvim_win_set_cursor(0, { f[1] + 1, f[2] })
    M.internal_visual = true
    pcall(vim.cmd, 'silent normal! ' .. n .. vim.keycode('<C-a>'))
    M.internal_visual = false
    local c = api.nvim_win_get_cursor(0)
    local l = sel.line(c[1] - 1)
    local st = c[2]
    while st > 0 and l:sub(st, st):match('[%x%-xXbBoO]') do
      st = st - 1
    end
    if not l:sub(st + 1, st + 1):match('[%w%-]') then
      st = st + 1
    end
    return { a = { c[1] - 1, st }, h = { c[1] - 1, c[2] } }
  end)
end)

cmd('decrement', 'Decrement item under cursor', function()
  local n = count()
  sel.transform(function(s)
    local f = sel.from(s)
    api.nvim_win_set_cursor(0, { f[1] + 1, f[2] })
    pcall(vim.cmd, 'silent normal! ' .. n .. vim.keycode('<C-x>'))
    local c = api.nvim_win_get_cursor(0)
    local l = sel.line(c[1] - 1)
    local st = c[2]
    while st > 0 and l:sub(st, st):match('[%x%-xXbBoO]') do
      st = st - 1
    end
    if not l:sub(st + 1, st + 1):match('[%w%-]') then
      st = st + 1
    end
    return { a = { c[1] - 1, st }, h = { c[1] - 1, c[2] } }
  end)
end)

local macro_reg ---@type string?

cmd('record_macro', 'Record macro', function()
  if fn.reg_recording() ~= '' then
    local r = fn.reg_recording()
    api.nvim_feedkeys('q', 'ni', false)
    vim.schedule(function()
      -- Drop the trailing "Q" that stopped the recording.
      local text = fn.getreg(r)
      if text:sub(-1) == 'Q' then
        fn.setreg(r, text:sub(1, -2))
      end
      notify('Recorded to register ' .. (macro_reg or r))
    end)
    return
  end
  macro_reg = take_reg('@')
  local vr = macro_reg == '@' and 'q' or macro_reg
  api.nvim_feedkeys('q' .. vr, 'ni', false)
end)

cmd('replay_macro', 'Replay macro', function()
  local r = take_reg('@')
  local vr = r == '@' and 'q' or r
  if fn.getreg(vr) == '' then
    notify('Register ' .. r .. ' is empty', vim.log.levels.WARN)
    return
  end
  api.nvim_feedkeys(count() .. '@' .. vr, 'ni', false)
end)

cmd('suspend', 'Suspend and return to shell', function()
  vim.cmd.suspend()
end)

cmd('join_selections', 'Join lines inside selection', function()
  sel.transform(function(s)
    local f, t = sel.from(s), sel.to(s)
    local r1, r2 = f[1], t[1]
    if r1 == r2 then
      r2 = math.min(r1 + 1, sel.line_count() - 1)
    end
    local a, h = sel.mark(s.a), sel.mark(s.h)
    for row = r2, r1 + 1, -1 do
      local prev, cur = sel.line(row - 1), sel.line(row)
      local lead = #(cur:match('^%s*'))
      local ptrim = #(prev:match('^(.-)%s*$'))
      local sep = (lead == #cur or ptrim == 0) and '' or ' '
      api.nvim_buf_set_text(0, row - 1, ptrim, row, lead, { sep })
    end
    return { a = sel.unmark(a), h = sel.unmark(h) }
  end)
end)

cmd('join_selections_space', 'Join lines inside selection and select spaces', function()
  sel.transform(function(s)
    local f, t = sel.from(s), sel.to(s)
    local r1, r2 = f[1], t[1]
    if r1 == r2 then
      r2 = math.min(r1 + 1, sel.line_count() - 1)
    end
    local spaces = {}
    for row = r2, r1 + 1, -1 do
      local prev, cur = sel.line(row - 1), sel.line(row)
      local lead = #(cur:match('^%s*'))
      local ptrim = #(prev:match('^(.-)%s*$'))
      api.nvim_buf_set_text(0, row - 1, ptrim, row, lead, { ' ' })
      spaces[#spaces + 1] = sel.mark({ row - 1, ptrim })
    end
    local out = {}
    for j = #spaces, 1, -1 do
      local p = sel.unmark(spaces[j])
      out[#out + 1] = { a = p, h = p }
    end
    return #out > 0 and out or s
  end, { keep_primary = true })
end)

-- }}}

-- Shell {{{

local function shell(label, f)
  local c = prompt(label)
  if not c or c == '' then
    return
  end
  f(c)
end

local function run_shell(c, input)
  local out = fn.system({ vim.o.shell, vim.o.shellcmdflag, c }, input)
  return out, vim.v.shell_error
end

cmd('shell_pipe', 'Pipe selections through shell command', function()
  shell('pipe: ', function(c)
    sel.transform(function(s)
      local text = sel.text(s)
      local out, code = run_shell(c, text)
      if code ~= 0 then
        notify(('Shell command failed (%d): %s'):format(code, out), vim.log.levels.ERROR)
        return s
      end
      if text:sub(-1) ~= '\n' and out:sub(-1) == '\n' then
        out = out:sub(1, -2)
      end
      return sel.replace(s, out)
    end)
  end)
end)

cmd('shell_pipe_to', 'Pipe selections into shell command ignoring output', function()
  shell('pipe-to: ', function(c)
    for _, s in ipairs(sel.get().sels) do
      run_shell(c, sel.text(s))
    end
  end)
end)

local function shell_insert(after)
  return function()
    shell(after and 'append-output: ' or 'insert-output: ', function(c)
      local out, code = run_shell(c)
      if code ~= 0 then
        notify(('Shell command failed (%d): %s'):format(code, out), vim.log.levels.ERROR)
        return
      end
      if out == '' then
        return
      end
      sel.transform(function(s)
        local p = after and sel.after(sel.to(s)) or sel.from(s)
        if after and sel.cmp(p, sel.to(s)) == 0 then
          p = { p[1], #sel.line(p[1]) }
        end
        local e = sel.insert(p, out)
        return { a = p, h = e }
      end)
    end)
  end
end

cmd('shell_insert_output', 'Insert shell command output before selections', shell_insert(false))
cmd('shell_append_output', 'Append shell command output after selections', shell_insert(true))

cmd('shell_keep_pipe', 'Keep selections where shell command returned 0', function()
  shell('keep-pipe: ', function(c)
    local st = sel.get()
    local keep = {}
    for _, s in ipairs(st.sels) do
      local _, code = run_shell(c, sel.text(s))
      if code == 0 then
        keep[#keep + 1] = s
      end
    end
    if #keep == 0 then
      notify('No selections remaining', vim.log.levels.WARN)
      return
    end
    sel.set(keep, 1)
  end)
end)

-- }}}

-- Selection manipulation {{{

local function regex_prompt(label, apply)
  local last
  local text = prompt(label, function(t)
    local re = compile(M.regex(t))
    if re then
      apply(re, true)
    end
  end)
  if not text or text == '' then
    return
  end
  last = M.regex(text)
  local re = compile(last)
  if not re then
    notify('Invalid regex: ' .. text, vim.log.levels.ERROR)
    return
  end
  reg_write('/', { last })
  apply(re, false)
end

cmd('select_regex', 'Select all regex matches inside selections', function()
  regex_prompt('select: ', function(re)
    local st = sel.get()
    local out = {}
    for _, s in ipairs(st.sels) do
      vim.list_extend(out, matches_in(re, s))
    end
    if #out > 0 then
      sel.set(out, #out)
    end
  end)
end)

cmd('split_selection', 'Split selections on regex matches', function()
  regex_prompt('split: ', function(re)
    local st = sel.get()
    local out = {}
    for _, s in ipairs(st.sels) do
      local start = sel.from(s)
      for _, m in ipairs(matches_in(re, s)) do
        local before = sel.prev(m.a)
        if before and sel.cmp(before, start) >= 0 then
          out[#out + 1] = { a = start, h = before }
        end
        start = sel.next(m.h) or m.h
      end
      if sel.cmp(start, sel.to(s)) <= 0 then
        out[#out + 1] = { a = start, h = sel.to(s) }
      end
    end
    if #out > 0 then
      sel.set(out, #out)
    end
  end)
end)

cmd('split_selection_on_newline', 'Split selection on newlines', function()
  local st = sel.get()
  local out = {}
  for _, s in ipairs(st.sels) do
    local f, t = sel.from(s), sel.to(s)
    for r = f[1], t[1] do
      local l = sel.line(r)
      local c1 = r == f[1] and f[2] or 0
      local c2 = r == t[1] and math.min(t[2], #l - 1) or #l - 1
      if r == t[1] and t[2] >= #l and r ~= f[1] and #l == 0 then
        break
      end
      if c2 >= c1 then
        out[#out + 1] = { a = { r, c1 }, h = sel.clamp({ r, c2 }) }
      elseif #l == 0 or c1 >= #l then
        if r ~= t[1] or t[2] < #l then
          out[#out + 1] = { a = { r, c1 }, h = { r, c1 } }
        end
      end
    end
  end
  if #out > 0 then
    sel.set(out, #out)
  end
end)

cmd('merge_selections', 'Merge selections', function()
  local st = sel.get()
  local f, t = sel.from(st.sels[1]), sel.to(st.sels[1])
  for _, s in ipairs(st.sels) do
    if sel.cmp(sel.from(s), f) < 0 then
      f = sel.from(s)
    end
    if sel.cmp(sel.to(s), t) > 0 then
      t = sel.to(s)
    end
  end
  sel.set({ { a = f, h = t } }, 1)
end)

cmd('merge_consecutive_selections', 'Merge consecutive selections', function()
  local st = sel.get()
  local out, primary = {}, 1
  for i, s in ipairs(st.sels) do
    local last = out[#out]
    local n = last and sel.next(sel.to(last))
    if last and n and sel.cmp(n, sel.from(s)) == 0 then
      last.h = sel.to(s)
      last.a = sel.from(last)
    else
      out[#out + 1] = { a = sel.from(s), h = sel.to(s) }
    end
    if i == st.primary then
      primary = #out
    end
  end
  sel.set(out, primary)
end)

cmd('align_selections', 'Align selections in column', function()
  local st = sel.get()
  -- Group by index within line: the k-th selection on each line forms a column.
  local per_line = {} ---@type table<integer, integer>
  local cols = {} ---@type table<integer, integer[]>
  for i, s in ipairs(st.sels) do
    local f = sel.from(s)
    if sel.to(s)[1] ~= f[1] then
      notify('Align: multi-line selections are not supported', vim.log.levels.WARN)
      return
    end
    per_line[f[1]] = (per_line[f[1]] or 0) + 1
    local k = per_line[f[1]]
    cols[k] = cols[k] or {}
    table.insert(cols[k], i)
  end
  for k = 1, #cols do
    local maxc = 0
    for _, i in ipairs(cols[k]) do
      maxc = math.max(maxc, vcol(sel.from(st.sels[i])))
    end
    local col_set = {}
    for _, i in ipairs(cols[k]) do
      col_set[i] = true
    end
    sel.transform(function(s, i)
      if not col_set[i] then
        return s
      end
      local f = sel.from(s)
      local pad = maxc - vcol(f)
      if pad > 0 then
        local a, h = sel.mark(s.a), sel.mark(s.h)
        api.nvim_buf_set_text(0, f[1], f[2], f[1], f[2], { (' '):rep(pad) })
        return { a = sel.unmark(a), h = sel.unmark(h) }
      end
      return s
    end)
    st = sel.get()
  end
end)

cmd('trim_selections', 'Trim whitespace from selections', function()
  local st = sel.get()
  local out, primary = {}, 1
  for i, s in ipairs(st.sels) do
    local f, t = sel.from(s), sel.to(s)
    while sel.cmp(f, t) < 0 and sel.char(f):match('^%s$') do
      f = sel.next(f) or f
    end
    while sel.cmp(t, f) > 0 and sel.char(t):match('^%s$') do
      t = sel.prev(t) or t
    end
    if not (sel.cmp(f, t) == 0 and sel.char(f):match('^%s$')) then
      local backward = sel.cmp(s.h, s.a) < 0
      out[#out + 1] = backward and { a = t, h = f } or { a = f, h = t }
      if i == st.primary then
        primary = #out
      end
    end
  end
  if #out > 0 then
    sel.set(out, primary)
  end
end)

cmd('collapse_selection', 'Collapse selection into single cursor', function()
  local st = sel.get()
  for _, s in ipairs(st.sels) do
    s.a = vim.deepcopy(s.h)
  end
  sel.set(st.sels, st.primary)
end)

cmd('flip_selections', 'Flip selection cursor and anchor', function()
  local st = sel.get()
  for _, s in ipairs(st.sels) do
    s.a, s.h = s.h, s.a
  end
  sel.set(st.sels, st.primary)
end)

cmd('ensure_selections_forward', 'Ensure all selections face forward', function()
  local st = sel.get()
  for _, s in ipairs(st.sels) do
    s.a, s.h = sel.from(s), sel.to(s)
  end
  sel.set(st.sels, st.primary)
end)

cmd('keep_primary_selection', 'Keep primary selection', function()
  sel.set({ sel.primary() }, 1)
end)

cmd('remove_primary_selection', 'Remove primary selection', function()
  local st = sel.get()
  if #st.sels == 1 then
    notify('no selections remaining', vim.log.levels.WARN)
    return
  end
  table.remove(st.sels, st.primary)
  sel.set(st.sels, math.min(st.primary, #st.sels))
end)

local function copy_selection(dir)
  local n = count()
  local st = sel.get()
  local out = vim.deepcopy(st.sels)
  local primary = st.primary
  for _ = 1, n do
    local added = {}
    for i, s in ipairs(st.sels) do
      local f, t = sel.from(s), sel.to(s)
      local height = t[1] - f[1] + 1
      local va, vh = vcol(s.a), vcol(s.h)
      local ra, rh = s.a[1], s.h[1]
      local step = dir * height
      while true do
        ra, rh = ra + step, rh + step
        if math.min(ra, rh) < 0 or math.max(ra, rh) >= sel.line_count() then
          break
        end
        local la, lh = sel.line(ra), sel.line(rh)
        local wa, wh = fn.strdisplaywidth(la), fn.strdisplaywidth(lh)
        if va <= wa and vh <= wh then
          local ns = { a = { ra, col_at_vcol(ra, va) }, h = { rh, col_at_vcol(rh, vh) } }
          added[#added + 1] = ns
          if i == st.primary then
            added.primary = #added
          end
          break
        end
      end
    end
    for j, s in ipairs(added) do
      out[#out + 1] = s
      if added.primary == j then
        primary = #out
      end
    end
    st = { sels = added, primary = added.primary or 1 }
    if #added == 0 then
      break
    end
  end
  sel.set(out, primary)
end

cmd('copy_selection_on_next_line', 'Copy selection on next line', function()
  copy_selection(1)
end)
cmd('copy_selection_on_prev_line', 'Copy selection on previous line', function()
  copy_selection(-1)
end)

local function rotate(dir)
  local st = sel.get()
  local n = count()
  st.primary = ((st.primary - 1 + dir * n) % #st.sels) + 1
  sel.sync_cursor()
  sel.render()
end

cmd('rotate_selections_backward', 'Rotate selections backward', function()
  rotate(-1)
end)
cmd('rotate_selections_forward', 'Rotate selections forward', function()
  rotate(1)
end)

local function rotate_contents(dir)
  local st = sel.get()
  local texts = vim.tbl_map(sel.text, st.sels)
  local k = #texts
  sel.transform(function(s, i)
    local src = ((i - 1 - dir) % k) + 1
    return sel.replace(s, texts[src])
  end)
end

cmd('rotate_selection_contents_backward', 'Rotate selection contents backward', function()
  rotate_contents(-1)
end)
cmd('rotate_selection_contents_forward', 'Rotate selection contents forward', function()
  rotate_contents(1)
end)

cmd('select_all', 'Select whole document', function()
  local last = sel.line_count() - 1
  sel.set({ { a = { 0, 0 }, h = { last, #sel.line(last) } } }, 1)
end)

cmd('extend_line_below', 'Select current line, if already selected, extend to next line', function()
  local n = count()
  local st = sel.get()
  local lc = sel.line_count()
  for _, s in ipairs(st.sels) do
    local f, t = sel.from(s), sel.to(s)
    local full = f[2] == 0 and t[2] >= #sel.line(t[1])
    local r2 = full and math.min(lc - 1, t[1] + n) or math.min(lc - 1, t[1] + n - 1)
    s.a, s.h = { f[1], 0 }, { r2, #sel.line(r2) }
  end
  sel.set(st.sels, st.primary)
end)

cmd('extend_line_above', 'Select current line, if selected, extend to previous line', function()
  local n = count()
  local st = sel.get()
  for _, s in ipairs(st.sels) do
    local f, t = sel.from(s), sel.to(s)
    local full = f[2] == 0 and t[2] >= #sel.line(t[1])
    local r1 = full and math.max(0, f[1] - n) or math.max(0, f[1] - n + 1)
    s.a, s.h = { t[1], #sel.line(t[1]) }, { r1, 0 }
  end
  sel.set(st.sels, st.primary)
end)

cmd('extend_to_line_bounds', 'Extend selection to line bounds', function()
  local st = sel.get()
  for _, s in ipairs(st.sels) do
    local f, t = sel.from(s), sel.to(s)
    local backward = sel.cmp(s.h, s.a) < 0
    local nf, nt = { f[1], 0 }, { t[1], #sel.line(t[1]) }
    s.a, s.h = backward and nt or nf, backward and nf or nt
  end
  sel.set(st.sels, st.primary)
end)

cmd('shrink_to_line_bounds', 'Shrink selection to line bounds', function()
  local st = sel.get()
  for _, s in ipairs(st.sels) do
    local f, t = sel.from(s), sel.to(s)
    local r1 = f[2] == 0 and f[1] or f[1] + 1
    local r2 = t[2] >= #sel.line(t[1]) and t[1] or t[1] - 1
    if r1 <= r2 then
      local backward = sel.cmp(s.h, s.a) < 0
      local nf, nt = { r1, 0 }, { r2, #sel.line(r2) }
      s.a, s.h = backward and nt or nf, backward and nf or nt
    end
  end
  sel.set(st.sels, st.primary)
end)

local function keep_or_remove(keep)
  return function()
    regex_prompt(keep and 'keep: ' or 'remove: ', function(re)
      local st = sel.get()
      local out, primary = {}, 1
      for i, s in ipairs(st.sels) do
        local m = #matches_in(re, s) > 0
        if m == keep then
          out[#out + 1] = s
          if i == st.primary then
            primary = #out
          end
        end
      end
      if #out > 0 then
        sel.set(out, primary)
      end
    end)
  end
end

cmd('keep_selections', 'Keep selections matching regex', keep_or_remove(true))
cmd('remove_selections', 'Remove selections matching regex', keep_or_remove(false))

--- Runs `f()`, which changes lines in place (same line count), keeping
--- selections on the same lines: line start/end stay at line start/end,
--- other columns shift with the line length.
local function keep_lines(f)
  local st = sel.get()
  local before = {}
  for i, s in ipairs(st.sels) do
    before[i] = { #sel.line(s.a[1]), #sel.line(s.h[1]) }
  end
  f()
  local function adjust(p, oldlen)
    local newlen = #sel.line(p[1])
    if p[2] == 0 then
      return p
    elseif p[2] >= oldlen then
      return { p[1], newlen }
    end
    return sel.clamp({ p[1], math.max(0, p[2] + newlen - oldlen) })
  end
  local new = {}
  for i, s in ipairs(st.sels) do
    new[i] = { a = adjust(s.a, before[i][1]), h = adjust(s.h, before[i][2]) }
  end
  sel.set(new, st.primary)
end

local function comment_lines()
  local toggle = require('vim._comment').toggle_lines
  keep_lines(function()
    local ranges = line_ranges()
    for i = #ranges, 1, -1 do
      toggle(ranges[i][1] + 1, ranges[i][2] + 1, { ranges[i][1] + 1, 0 })
    end
  end)
end

local function comment_block()
  local cs = vim.bo.commentstring
  local l, r = cs:match('^(.-)%s*%%s%s*(.-)$')
  if not l or r == '' then
    comment_lines()
    return
  end
  sel.transform(function(s)
    local text = sel.text(s)
    local inner = text:match('^' .. vim.pesc(l) .. '%s?(.-)%s?' .. vim.pesc(r) .. '$')
    if inner then
      return sel.replace(s, inner)
    end
    return sel.replace(s, l .. ' ' .. text .. ' ' .. r)
  end)
end

cmd('toggle_comments', 'Comment/uncomment selections', function()
  local multi_line = false
  for _, s in ipairs(sel.get().sels) do
    if sel.from(s)[1] ~= sel.to(s)[1] or sel.cmp(s.a, s.h) == 0 then
      multi_line = true
    end
  end
  local cs = vim.bo.commentstring
  local _, r = cs:match('^(.-)%s*%%s%s*(.-)$')
  if not multi_line and r and r ~= '' then
    -- Partial-line selections in languages with block comments.
    local s = sel.primary()
    local f, t = sel.from(s), sel.to(s)
    if f[2] > 0 or t[2] < #sel.line(t[1]) - 1 then
      comment_block()
      return
    end
  end
  comment_lines()
end)
cmd('toggle_block_comments', 'Block comment/uncomment selections', comment_block)
cmd('toggle_line_comments', 'Line comment/uncomment selections', comment_lines)

-- Tree-sitter.

local function ts_each(f, name)
  local ts = require('vim._core.helix_ts')
  if not ts.available() then
    notify(name .. ': no tree-sitter parser for this buffer', vim.log.levels.WARN)
    return
  end
  local st = sel.get()
  local out, primary = {}, st.primary
  for i, s in ipairs(st.sels) do
    local r = f(ts, s)
    if r and r.a then
      out[#out + 1] = r
    elseif r then
      vim.list_extend(out, r)
    else
      out[#out + 1] = s
    end
    if i == st.primary then
      primary = #out
    end
  end
  sel.set(out, primary)
  return out
end

cmd('expand_selection', 'Expand selection to parent syntax node', function()
  local st = sel.get()
  local before = vim.deepcopy(st.sels)
  local bp = st.primary
  local after = ts_each(function(ts, s)
    return ts.expand(s)
  end, 'expand_selection')
  if after then
    st.history = st.history or {}
    local after = vim.deepcopy(sel.get().sels)
    table.insert(st.history, { before = before, primary = bp, after = after })
  end
end)

cmd('shrink_selection', 'Shrink selection to previously expanded syntax node', function()
  local st = sel.get()
  local top = st.history and st.history[#st.history]
  if top and vim.deep_equal(top.after, st.sels) then
    table.remove(st.history)
    sel.set(vim.deepcopy(top.before), top.primary)
    return
  end
  st.history = nil
  ts_each(function(ts, s)
    return ts.shrink(s)
  end, 'shrink_selection')
end)

cmd('select_next_sibling', 'Select next sibling in the syntax tree', function()
  ts_each(function(ts, s)
    return ts.sibling(s, true)
  end, 'select_next_sibling')
end)
cmd('select_prev_sibling', 'Select previous sibling in the syntax tree', function()
  ts_each(function(ts, s)
    return ts.sibling(s, false)
  end, 'select_prev_sibling')
end)
cmd('select_all_siblings', 'Select all siblings of the current node', function()
  ts_each(function(ts, s)
    return ts.all_siblings(s)
  end, 'select_all_siblings')
end)
cmd('select_all_children', 'Select all children of the current node', function()
  ts_each(function(ts, s)
    return ts.all_children(s)
  end, 'select_all_children')
end)

local function parent_edge(to_end)
  local ts = require('vim._core.helix_ts')
  if not ts.available() then
    notify('no tree-sitter parser for this buffer', vim.log.levels.WARN)
    return
  end
  motion(function(s)
    return ts.parent_edge(s, to_end)
  end)
end

cmd('move_parent_node_end', 'Move to end of the parent node', function()
  parent_edge(true)
end)
cmd('move_parent_node_start', 'Move to beginning of the parent node', function()
  parent_edge(false)
end)

-- }}}

-- Search {{{

--- Selects the next match of the search register.
---@param backward boolean
---@param vpat? string
local function search_next(backward, vpat)
  vpat = vpat or reg_read('/')[1]
  if not vpat or vpat == '' then
    notify('No search pattern', vim.log.levels.WARN)
    return
  end
  local st = sel.get()
  local s = st.sels[st.primary]
  local from = backward and sel.from(s) or sel.to(s)
  local n = count()
  local m, wrapped
  for _ = 1, n do
    local w
    m, w = find(vpat, from, backward)
    if not m then
      break
    end
    wrapped = wrapped or w
    from = backward and m.a or m.h
  end
  if not m then
    notify('No more matches', vim.log.levels.WARN)
    return
  end
  if wrapped then
    notify('Wrapped around document')
  end
  push_jump()
  local sels = vim.deepcopy(st.sels)
  if M.mode == 'select' then
    sels[#sels + 1] = m
  else
    table.remove(sels, st.primary)
    sels[#sels + 1] = m
  end
  -- The new match becomes primary.
  sel.set(sels, #sels)
end

local function search_prompt(backward)
  local label = backward and '?' or '/'
  local text = prompt(label, function(t)
    local p = M.regex(t)
    if compile(p) then
      local st = sel.get()
      local s = st.sels[st.primary]
      local m = find(p, backward and sel.from(s) or sel.to(s), backward)
      if m then
        sel.set({ m }, 1)
      end
    end
  end)
  if not text then
    return
  end
  local p = text == '' and reg_read('/')[1] or M.regex(text)
  if not p or not compile(p) then
    notify('Invalid regex: ' .. text, vim.log.levels.ERROR)
    return
  end
  local r = take_reg('/')
  reg_write(r, { p })
  if r ~= '/' then
    reg_write('/', { p })
  end
  pcall(fn.histadd, '/', p)
  search_next(backward, p)
end

cmd('search', 'Search for regex pattern', function()
  search_prompt(false)
end)
cmd('rsearch', 'Reverse search for regex pattern', function()
  search_prompt(true)
end)
cmd('search_next', 'Select next search match', function()
  search_next(false)
end)
cmd('search_prev', 'Select previous search match', function()
  search_next(true)
end)

local function search_selection(detect)
  local pats, seen = {}, {}
  for _, s in ipairs(sel.get().sels) do
    local text = sel.text(s)
    local p = '\\V' .. text:gsub('\\', '\\\\'):gsub('\n', '\\n')
    if detect then
      local f, t = sel.from(s), sel.to(s)
      local before = sel.prev(f)
      local after = sel.next(t)
      local first_word = C_(f) == 'word'
      local last_word = C_(t) == 'word'
      if first_word and (not before or C_(before) ~= 'word') then
        p = p:gsub('^\\V', '\\V\\<')
      end
      if last_word and (not after or C_(after) ~= 'word') then
        p = p .. '\\>'
      end
    end
    if not seen[p] then
      seen[p] = true
      pats[#pats + 1] = p
    end
  end
  local p = table.concat(pats, '\\|')
  local r = take_reg('/')
  reg_write(r, { p })
  if r ~= '/' then
    reg_write('/', { p })
  end
  notify(("register '/' set to '%s'"):format(p))
end

cmd('search_selection_detect_word_boundaries', 'Use current selection as search pattern', function()
  search_selection(true)
end)
cmd('search_selection', 'Use current selection as search pattern', function()
  search_selection(false)
end)

-- }}}

-- Info box & prefix (minor) modes {{{

local info_win ---@type integer?

local function close_info()
  if info_win and api.nvim_win_is_valid(info_win) then
    api.nvim_win_close(info_win, true)
  end
  info_win = nil
end

---@param title string
---@param entries {[1]: string, [2]: string}[]
local function show_info(title, entries)
  close_info()
  if vim.g.helix_infobox == false or fn.getchar(1) ~= 0 or #api.nvim_list_uis() == 0 then
    return
  end
  local kw = 0
  for _, e in ipairs(entries) do
    kw = math.max(kw, fn.strdisplaywidth(e[1]))
  end
  local cells, cw = {}, 0
  for _, e in ipairs(entries) do
    local l = ' ' .. e[1] .. (' '):rep(kw - fn.strdisplaywidth(e[1])) .. '  ' .. e[2] .. ' '
    cells[#cells + 1] = l
    cw = math.max(cw, fn.strdisplaywidth(l))
  end
  -- Use several columns when the entries don't fit the screen height.
  local maxh = math.max(1, vim.o.lines - vim.o.cmdheight - 4)
  local ncol = math.ceil(#cells / maxh)
  ncol = math.max(1, math.min(ncol, math.floor((vim.o.columns - 2) / math.max(1, cw))))
  local nrow = math.ceil(#cells / ncol)
  local lines = {}
  for r = 1, nrow do
    local parts = {}
    for c = 0, ncol - 1 do
      local cell = cells[c * nrow + r]
      if cell then
        parts[#parts + 1] = cell .. (' '):rep(cw - fn.strdisplaywidth(cell))
      end
    end
    lines[r] = table.concat(parts)
  end
  local w = math.min(vim.o.columns - 2, math.max(#title + 2, cw * ncol))
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = 'wipe'
  local h = math.min(#lines, vim.o.lines - 4)
  info_win = api.nvim_open_win(buf, false, {
    relative = 'editor',
    anchor = 'SE',
    row = vim.o.lines - vim.o.cmdheight - 1,
    col = vim.o.columns,
    width = w,
    height = h,
    style = 'minimal',
    border = vim.o.winborder ~= '' and vim.o.winborder or 'rounded',
    title = ' ' .. title .. ' ',
    focusable = false,
    noautocmd = true,
    zindex = 250,
  })
  vim.cmd.redraw()
end

---@alias nvim.helix.Entry {[1]: string|string[], [2]: string|fun(), [3]?: string}

--- Builds a function that reads a key and dispatches to `entries`.
---@param title string
---@param entries nvim.helix.Entry[]
---@param sticky? boolean stay in the mode until <Esc>
local function prefix(title, entries, sticky, keyprefix)
  local lookup = {} ---@type table<string, fun()>
  local info = {}
  for _, e in ipairs(entries) do
    local keys = type(e[1]) == 'table' and e[1] or { e[1] }
    local f = e[2]
    local desc = e[3]
    if type(f) == 'string' then
      local c = M.commands[f]
      desc = desc or (c and c.desc) or f
      if c and keyprefix then
        local k = keyprefix .. ' ' .. table.concat(keys --[[@as string[] ]], '/')
        c.keys = c.keys and (c.keys .. ', ' .. k) or k
      end
      local name = f
      f = function()
        M.commands[name].fn()
      end
    end
    for _, k in ipairs(keys --[[@as string[] ]]) do
      lookup[vim.keycode(k)] = f
    end
    info[#info + 1] = { table.concat(keys --[[@as string[] ]], ', '), desc or '' }
  end
  return function()
    repeat
      show_info(title, info)
      local k = getkey()
      close_info()
      if not k then
        return
      end
      local f = lookup[k]
      if f then
        f()
        if sticky then
          vim.cmd.redraw()
        end
      elseif not sticky then
        return
      end
    until not sticky
  end
end

-- View mode.

local function view(keys)
  return function()
    sel.sync_cursor()
    sel.busy = true
    pcall(vim.cmd, 'normal! ' .. vim.keycode(keys))
    sel.busy = false
    local c = api.nvim_win_get_cursor(0)
    local h = sel.primary().h
    if c[1] - 1 ~= h[1] or c[2] ~= h[2] then
      -- The scroll moved the cursor: move the selection along.
      sel.reset_to_cursor()
    end
  end
end

cmd('align_view_center', 'Align view center', view('zz'))
cmd('align_view_top', 'Align view top', view('zt'))
cmd('align_view_bottom', 'Align view bottom', view('zb'))
cmd('align_view_middle', 'Align view middle', function()
  if vim.wo.wrap then
    return
  end
  local v = fn.winsaveview()
  local w = api.nvim_win_get_width(0) - fn.getwininfo(api.nvim_get_current_win())[1].textoff
  v.leftcol = math.max(0, vcol(sel.primary().h) - math.floor(w / 2))
  fn.winrestview(v)
end)
cmd('scroll_down', 'Scroll view down', function()
  view(count() .. '<C-e>')()
end)
cmd('scroll_up', 'Scroll view up', function()
  view(count() .. '<C-y>')()
end)

local view_entries = {
  { { 'z', 'c' }, 'align_view_center', 'Align view center' },
  { 't', 'align_view_top' },
  { 'b', 'align_view_bottom' },
  { 'm', 'align_view_middle' },
  { { 'j', '<Down>' }, 'scroll_down' },
  { { 'k', '<Up>' }, 'scroll_up' },
  { { '<C-f>', '<PageDown>' }, 'page_down' },
  { { '<C-b>', '<PageUp>' }, 'page_up' },
  { '<C-u>', 'page_cursor_half_up' },
  { '<C-d>', 'page_cursor_half_down' },
}

-- Goto mode.

local function lsp_supports(method)
  return #vim.lsp.get_clients({ bufnr = 0, method = method }) > 0
end

local function items_picker(title, items)
  require('vim._core.helix_picker').open({ title = title, items = items })
end

--- LSP location request; jumps directly when there's a single result.
local function lsp_goto(method, f, title)
  return function()
    if type(f) == 'string' then
      f = vim.lsp.buf[f]
    end
    if not lsp_supports(method) then
      notify('No configured language server supports ' .. method, vim.log.levels.WARN)
      return
    end
    sel.sync_cursor()
    f({
      on_list = function(opts)
        local items = opts.items or {}
        if #items == 0 then
          notify('No ' .. title .. ' found', vim.log.levels.WARN)
        elseif #items == 1 then
          require('vim._core.helix_picker').jump({
            text = items[1].text or '',
            file = items[1].filename,
            buf = items[1].bufnr,
            lnum = items[1].lnum,
            col = items[1].col,
          }, 'edit')
        else
          local pitems = {}
          for _, it in ipairs(items) do
            pitems[#pitems + 1] = {
              text = ('%s:%d:%d %s'):format(
                fn.fnamemodify(it.filename or '', ':.'),
                it.lnum,
                it.col,
                vim.trim(it.text or '')
              ),
              file = it.filename,
              lnum = it.lnum,
              col = it.col,
            }
          end
          items_picker(title, pitems)
        end
      end,
    })
  end
end

cmd(
  'goto_definition',
  'Goto definition',
  lsp_goto('textDocument/definition', 'definition', 'definition')
)
cmd(
  'goto_declaration',
  'Goto declaration',
  lsp_goto('textDocument/declaration', 'declaration', 'declaration')
)
cmd(
  'goto_type_definition',
  'Goto type definition',
  lsp_goto('textDocument/typeDefinition', 'type_definition', 'type definition')
)
cmd(
  'goto_implementation',
  'Goto implementation',
  lsp_goto('textDocument/implementation', 'implementation', 'implementation')
)
cmd(
  'goto_reference',
  'Goto references',
  lsp_goto('textDocument/references', function(opts)
    vim.lsp.buf.references({ includeDeclaration = true }, opts)
  end, 'references')
)

cmd('goto_file', 'Goto files/URLs in selections', function()
  local targets = {}
  for _, s in ipairs(sel.get().sels) do
    local t
    if sel.cmp(s.a, s.h) == 0 then
      sel.busy = true
      api.nvim_win_set_cursor(0, { s.h[1] + 1, s.h[2] })
      t = fn.expand('<cfile>')
      sel.busy = false
    else
      t = vim.trim(sel.text(s))
    end
    if t ~= '' then
      targets[#targets + 1] = t
    end
  end
  for _, t in ipairs(targets) do
    if t:match('^%a[%w+.-]*://') then
      vim.ui.open(t)
    else
      local path = t
      if not vim.uv.fs_stat(path) then
        local found = fn.findfile(t, vim.o.path ~= '' and vim.o.path or '.,,')
        path = found ~= '' and found or vim.fs.joinpath(fn.expand('%:p:h'), t)
      end
      vim.cmd.edit(fn.fnameescape(path))
    end
  end
end)

cmd('goto_last_accessed_file', 'Goto last accessed file', function()
  local ok = pcall(vim.cmd.buffer, '#')
  if not ok then
    notify('no last accessed buffer', vim.log.levels.WARN)
  end
end)

local last_modified ---@type integer[]
last_modified = {}

cmd('goto_last_modified_file', 'Goto last modified file', function()
  local cur = api.nvim_get_current_buf()
  for i = #last_modified, 1, -1 do
    local b = last_modified[i]
    if b ~= cur and api.nvim_buf_is_valid(b) then
      api.nvim_set_current_buf(b)
      return
    end
  end
  notify('no last modified buffer', vim.log.levels.WARN)
end)

cmd('goto_next_buffer', 'Goto next buffer', function()
  vim.cmd('silent! ' .. count() .. 'bnext')
end)
cmd('goto_previous_buffer', 'Goto previous buffer', function()
  vim.cmd('silent! ' .. count() .. 'bprevious')
end)

cmd('goto_last_modification', 'Goto last modification', function()
  local m = api.nvim_buf_get_mark(0, '.')
  if m[1] == 0 then
    notify('no modifications', vim.log.levels.WARN)
    return
  end
  push_jump()
  goto_pos({ m[1] - 1, m[2] })
end)

local label_ns = api.nvim_create_namespace('nvim.helix.labels')

cmd('goto_word', 'Jump to a two-character label', function()
  local alphabet = vim.g.helix_jump_label_alphabet or 'abcdefghijklmnopqrstuvwxyz'
  local top, bot = fn.line('w0') - 1, fn.line('w$') - 1
  local cur = sel.primary().h
  local words = {}
  for r = top, bot do
    local l = sel.line(r)
    local c = 0
    while c < #l do
      local ch = l:sub(c + 1, c + sel.charlen(l, c))
      local cls = sel.class(ch)
      local prevcls = c > 0 and sel.class(sel.char({ r, c - 1 })) or 'ws'
      if cls == 'word' and prevcls ~= 'word' then
        local e = c
        while e + 1 < #l and sel.class(sel.char({ r, e + 1 })) == 'word' do
          e = e + 1
        end
        if e > c then
          words[#words + 1] = { r, c, e }
        end
        c = e + 1
      else
        c = c + #ch
      end
    end
  end
  local function dist(w)
    return math.abs(w[1] - cur[1]) * 1000 + math.abs(w[2] - cur[2])
  end
  table.sort(words, function(x, y)
    return dist(x) < dist(y)
  end)
  local n = #alphabet
  local labels = {}
  for i, w in ipairs(words) do
    if i > n * n then
      break
    end
    local l = alphabet:sub(math.floor((i - 1) / n) + 1, math.floor((i - 1) / n) + 1)
      .. alphabet:sub((i - 1) % n + 1, (i - 1) % n + 1)
    labels[l] = w
  end
  local function draw(first)
    api.nvim_buf_clear_namespace(0, label_ns, 0, -1)
    for l, w in pairs(labels) do
      if not first or l:sub(1, 1) == first then
        api.nvim_buf_set_extmark(0, label_ns, w[1], w[2], {
          virt_text = { { first and l:sub(2) or l, 'HelixJumpLabel' } },
          virt_text_pos = 'overlay',
          priority = 300,
        })
      end
    end
    vim.cmd.redraw()
  end
  draw()
  local k1 = getkey()
  if not k1 then
    api.nvim_buf_clear_namespace(0, label_ns, 0, -1)
    return
  end
  draw(k1)
  local k2 = getkey()
  api.nvim_buf_clear_namespace(0, label_ns, 0, -1)
  local w = k2 and labels[k1 .. k2]
  if not w then
    return
  end
  push_jump()
  local s = { a = { w[1], w[2] }, h = { w[1], w[3] } }
  if M.mode == 'select' then
    s.a = sel.primary().a
  end
  sel.set({ s }, 1)
end)

local goto_entries = {
  { 'g', 'goto_file_start', 'Goto line number <n> else file start' },
  { '|', 'goto_column', 'Goto column' },
  { 'e', 'goto_last_line' },
  { 'f', 'goto_file' },
  { 'h', 'goto_line_start' },
  { 'l', 'goto_line_end' },
  { 's', 'goto_first_nonwhitespace' },
  { 't', 'goto_window_top' },
  { 'c', 'goto_window_center' },
  { 'b', 'goto_window_bottom' },
  { 'd', 'goto_definition' },
  { 'D', 'goto_declaration' },
  { 'y', 'goto_type_definition' },
  { 'r', 'goto_reference' },
  { 'i', 'goto_implementation' },
  { 'a', 'goto_last_accessed_file' },
  { 'm', 'goto_last_modified_file' },
  { 'n', 'goto_next_buffer' },
  { 'p', 'goto_previous_buffer' },
  { '.', 'goto_last_modification' },
  { 'j', 'move_line_down' },
  { 'k', 'move_line_up' },
  { 'w', 'goto_word' },
}

-- Match mode.

local pairs_open = { ['('] = ')', ['['] = ']', ['{'] = '}', ['<'] = '>' }
local pairs_close = { [')'] = '(', [']'] = '[', ['}'] = '{', ['>'] = '<' }

local function pair_of(ch)
  if pairs_open[ch] then
    return ch, pairs_open[ch]
  elseif pairs_close[ch] then
    return pairs_close[ch], ch
  end
  return ch, ch
end

cmd('match_brackets', 'Goto matching bracket', function()
  local ts = require('vim._core.helix_ts')
  motion(function(s)
    local p = ts.available() and ts.match_bracket(s.h)
    if p then
      return p
    end
    sel.busy = true
    api.nvim_win_set_cursor(0, { s.h[1] + 1, s.h[2] })
    pcall(vim.cmd, 'normal! %')
    local c = api.nvim_win_get_cursor(0)
    sel.busy = false
    return { c[1] - 1, c[2] }
  end)
end)

cmd('surround_add', 'Surround add', function()
  local k = getkey()
  if not k then
    return
  end
  local o, c = pair_of(k)
  sel.transform(function(s)
    local f, t = sel.from(s), sel.to(s)
    local e = sel.after(t)
    if sel.cmp(e, t) == 0 then
      e = { t[1], #sel.line(t[1]) }
    end
    api.nvim_buf_set_text(0, e[1], e[2], e[1], e[2], { c })
    api.nvim_buf_set_text(0, f[1], f[2], f[1], f[2], { o })
    local nt = t[1] == f[1] and { t[1], e[2] + #o } or { e[1], e[2] }
    return { a = f, h = nt }
  end)
end)

--- Finds the surrounding pair of `ch` around `s`: positions of open/close.
---@return nvim.helix.Pos?, nvim.helix.Pos?
local function find_surround(s, ch, n)
  local o, c = pair_of(ch)
  local f, t = sel.from(s), sel.to(s)
  if o == c then
    -- Same-char pairs: search backward and forward.
    local lo = f
    local found_o
    local k = n
    while true do
      local q = sel.prev(lo)
      if not q then
        break
      end
      lo = q
      if sel.char(lo) == o then
        k = k - 1
        if k == 0 then
          found_o = lo
          break
        end
      end
    end
    if sel.char(f) == o and not found_o then
      found_o = f
    end
    if not found_o then
      return nil
    end
    local hi = t
    k = n
    if sel.cmp(found_o, f) == 0 then
      hi = f
    end
    while true do
      local q = sel.next(hi)
      if not q then
        break
      end
      hi = q
      if sel.char(hi) == c then
        k = k - 1
        if k == 0 then
          return found_o, hi
        end
      end
    end
    return nil
  end
  -- Brackets: walk outward balancing nesting.
  local depth = 0
  local lo = f
  local k = n
  local open_pos
  if sel.char(f) == o then
    k = k - 1
    if k == 0 then
      open_pos = f
    end
  end
  while not open_pos do
    local q = sel.prev(lo)
    if not q then
      return nil
    end
    lo = q
    local ch2 = sel.char(lo)
    if ch2 == c then
      depth = depth + 1
    elseif ch2 == o then
      if depth == 0 then
        k = k - 1
        if k == 0 then
          open_pos = lo
        end
      else
        depth = depth - 1
      end
    end
  end
  depth = 0
  local hi = open_pos
  while true do
    local q = sel.next(hi)
    if not q then
      return nil
    end
    hi = q
    local ch2 = sel.char(hi)
    if ch2 == o then
      depth = depth + 1
    elseif ch2 == c then
      if depth == 0 then
        return open_pos, hi
      end
      depth = depth - 1
    end
  end
end

--- Closest surrounding bracket/quote pair (Helix `m` as the pair char).
local function closest_pair(s)
  local best_o, best_c
  for _, ch in ipairs({ '(', '[', '{', '<', '"', "'", '`' }) do
    local o, c = find_surround(s, ch, 1)
    if o and c and (not best_o or sel.cmp(o, best_o) > 0) then
      best_o, best_c = o, c
    end
  end
  return best_o, best_c
end

cmd('surround_delete', 'Surround delete', function()
  local n = count()
  local k = getkey()
  if not k then
    return
  end
  sel.transform(function(s)
    local o, c
    if k == 'm' then
      o, c = closest_pair(s)
    else
      o, c = find_surround(s, k, n)
    end
    if not o or not c then
      notify('Surround pair not found around all cursors', vim.log.levels.WARN)
      return s
    end
    -- Keep the selection on the content between the deleted chars.
    local function inside(p)
      if sel.cmp(p, o) <= 0 then
        return sel.next(o) or p
      elseif sel.cmp(p, c) >= 0 then
        return sel.prev(c) or p
      end
      return p
    end
    local a, h = sel.mark(inside(s.a)), sel.mark(inside(s.h))
    local ce = sel.after(c)
    api.nvim_buf_set_text(0, c[1], c[2], ce[1], ce[2], { '' })
    local oe = sel.after(o)
    api.nvim_buf_set_text(0, o[1], o[2], oe[1], oe[2], { '' })
    return { a = sel.unmark(a), h = sel.unmark(h) }
  end)
end)

cmd('surround_replace', 'Surround replace', function()
  local n = count()
  local from = getkey()
  if not from then
    return
  end
  local to = getkey()
  if not to then
    return
  end
  local no, nc = pair_of(to)
  sel.transform(function(s)
    local o, c
    if from == 'm' then
      o, c = closest_pair(s)
    else
      o, c = find_surround(s, from, n)
    end
    if not o or not c then
      notify('Surround pair not found around all cursors', vim.log.levels.WARN)
      return s
    end
    local a, h = sel.mark(s.a), sel.mark(s.h)
    local ce = sel.after(c)
    api.nvim_buf_set_text(0, c[1], c[2], ce[1], ce[2], { nc })
    local oe = sel.after(o)
    api.nvim_buf_set_text(0, o[1], o[2], oe[1], oe[2], { no })
    return { a = sel.unmark(a), h = sel.unmark(h) }
  end)
end)

--- Vim text object via Visual mode, from position `p`.
---@return nvim.helix.Sel?
local function vim_textobject(p, obj, n)
  sel.busy = true
  M.internal_visual = true
  api.nvim_win_set_cursor(0, { p[1] + 1, p[2] })
  local ok = pcall(vim.cmd, ('silent normal! v%d%s\27'):format(n, obj))
  M.internal_visual = false
  sel.busy = false
  if not ok then
    return nil
  end
  local a, b = api.nvim_buf_get_mark(0, '<'), api.nvim_buf_get_mark(0, '>')
  if a[1] == 0 then
    return nil
  end
  local s = { a = sel.clamp({ a[1] - 1, a[2] }), h = sel.clamp({ b[1] - 1, b[2] }) }
  if obj:sub(2) ~= 'p' and fn.visualmode() == 'V' then
    s.a[2] = 0
    s.h[2] = #sel.line(s.h[1])
  end
  if sel.cmp(s.a, s.h) == 0 and sel.cmp(s.a, p) == 0 and not obj:match('[wW]$') then
    -- Text object failed: Vim leaves a 1-char selection at the cursor.
    local ch = sel.char(p)
    local key = obj:sub(2)
    if ch ~= key and ch ~= (pairs_open[key] or '') and ch ~= (pairs_close[key] or '') then
      return nil
    end
  end
  return s
end

local ts_objects = {
  f = 'function',
  t = 'class',
  a = 'parameter',
  c = 'comment',
  T = 'test',
  e = 'entry',
  x = 'xml',
}

local function select_textobject(around)
  return function()
    local n = count()
    local k = getkey()
    if not k then
      return
    end
    local ts = require('vim._core.helix_ts')
    sel.transform(function(s)
      local r
      if ts_objects[k] then
        if not ts.available() then
          return s
        end
        r = ts.textobject(s, ts_objects[k], around)
      elseif k == 'm' then
        local o, c = closest_pair(s)
        if o and c then
          if around then
            r = { a = o, h = c }
          else
            r = { a = sel.next(o) or o, h = sel.prev(c) or c }
          end
        end
      elseif k == 'g' then
        r = nil -- Changes (diff hunks) are handled by `]g`.
      else
        local obj = (around and 'a' or 'i') .. k
        r = vim_textobject(sel.from(s), obj, n)
      end
      return r or s
    end)
  end
end

cmd('select_textobject_around', 'Select around object', select_textobject(true))
cmd('select_textobject_inner', 'Select inside object', select_textobject(false))

local textobject_info = {
  { 'w', 'Word' },
  { 'W', 'WORD' },
  { 'p', 'Paragraph' },
  { 't', 'Type definition (tree-sitter)' },
  { 'f', 'Function (tree-sitter)' },
  { 'a', 'Argument/parameter (tree-sitter)' },
  { 'c', 'Comment (tree-sitter)' },
  { 'T', 'Test (tree-sitter)' },
  { 'e', 'Data structure entry (tree-sitter)' },
  { 'x', '(X)HTML element (tree-sitter)' },
  { 'm', 'Closest surrounding pair' },
  { '( [ { < " \' `', 'Specified surround pairs' },
}

local function with_info(title, info, f)
  return function()
    show_info(title, info)
    -- `f` reads the key; close the box afterwards.
    local ok, err = pcall(f)
    close_info()
    if not ok then
      error(err, 0)
    end
  end
end

local match_entries = {
  { 'm', 'match_brackets' },
  { 's', 'surround_add' },
  { 'r', 'surround_replace' },
  { 'd', 'surround_delete' },
  {
    'a',
    with_info('Match around', textobject_info, C.select_textobject_around),
    'Select around object',
  },
  {
    'i',
    with_info('Match inside', textobject_info, C.select_textobject_inner),
    'Select inside object',
  },
}

-- Window mode.

local function wincmd(c)
  return function()
    local ok, err = pcall(vim.cmd, count() .. 'wincmd ' .. c)
    if not ok then
      notify(tostring(err), vim.log.levels.WARN)
    end
  end
end

local function swap_view(dir)
  return function()
    local w1 = api.nvim_get_current_win()
    vim.cmd('wincmd ' .. dir)
    local w2 = api.nvim_get_current_win()
    if w1 == w2 then
      return
    end
    local b1, b2 = api.nvim_win_get_buf(w1), api.nvim_win_get_buf(w2)
    local v1 = api.nvim_win_call(w1, fn.winsaveview)
    local v2 = api.nvim_win_call(w2, fn.winsaveview)
    api.nvim_win_set_buf(w1, b2)
    api.nvim_win_set_buf(w2, b1)
    api.nvim_win_call(w1, function()
      fn.winrestview(v2)
    end)
    api.nvim_win_call(w2, function()
      fn.winrestview(v1)
    end)
  end
end

cmd('rotate_view', 'Goto next window', wincmd('w'))
cmd('vsplit', 'Vertical right split', function()
  vim.cmd('rightbelow vsplit')
end)
cmd('hsplit', 'Horizontal bottom split', function()
  vim.cmd('rightbelow split')
end)
cmd('transpose_view', 'Transpose splits', function()
  local layout = fn.winlayout()
  if layout[1] == 'row' then
    vim.cmd('wincmd K')
  else
    vim.cmd('wincmd H')
  end
end)
cmd('goto_file_hsplit', 'Goto files in selections (hsplit)', function()
  vim.cmd('rightbelow split')
  C.goto_file()
end)
cmd('goto_file_vsplit', 'Goto files in selections (vsplit)', function()
  vim.cmd('rightbelow vsplit')
  C.goto_file()
end)
cmd('jump_view_left', 'Goto left window', wincmd('h'))
cmd('jump_view_down', 'Goto window below', wincmd('j'))
cmd('jump_view_up', 'Goto window above', wincmd('k'))
cmd('jump_view_right', 'Goto right window', wincmd('l'))
cmd('wclose', 'Close window', function()
  local ok, err = pcall(vim.cmd.close)
  if not ok then
    notify(tostring(err), vim.log.levels.WARN)
  end
end)
cmd('wonly', 'Close windows except current', function()
  vim.cmd.only()
end)
cmd('swap_view_left', 'Swap with left window', swap_view('h'))
cmd('swap_view_down', 'Swap with window below', swap_view('j'))
cmd('swap_view_up', 'Swap with window above', swap_view('k'))
cmd('swap_view_right', 'Swap with right window', swap_view('l'))
cmd('hsplit_new', 'Horizontal split scratch buffer', function()
  vim.cmd('rightbelow new')
end)
cmd('vsplit_new', 'Vertical split scratch buffer', function()
  vim.cmd('rightbelow vnew')
end)

local window_entries = {
  { { 'w', '<C-w>' }, 'rotate_view' },
  { { 'v', '<C-v>' }, 'vsplit' },
  { { 's', '<C-s>' }, 'hsplit' },
  { { 't', '<C-t>' }, 'transpose_view' },
  { 'f', 'goto_file_hsplit' },
  { 'F', 'goto_file_vsplit' },
  { { 'h', '<C-h>', '<Left>' }, 'jump_view_left' },
  { { 'j', '<C-j>', '<Down>' }, 'jump_view_down' },
  { { 'k', '<C-k>', '<Up>' }, 'jump_view_up' },
  { { 'l', '<C-l>', '<Right>' }, 'jump_view_right' },
  { { 'q', '<C-q>' }, 'wclose' },
  { { 'o', '<C-o>' }, 'wonly' },
  { 'H', 'swap_view_left' },
  { 'J', 'swap_view_down' },
  { 'K', 'swap_view_up' },
  { 'L', 'swap_view_right' },
  {
    'n',
    prefix('New split scratch buffer', {
      { { 's', '<C-s>' }, 'hsplit_new' },
      { { 'v', '<C-v>' }, 'vsplit_new' },
    }, false, '<C-w> n'),
    'New split scratch buffer',
  },
}

-- Space mode.

local function root_dir()
  local ws = vim.lsp.buf.list_workspace_folders()
  if ws[1] then
    return ws[1]
  end
  return vim.fs.root(0, { '.git', '.jj', '.hg', '.svn' }) or vim.uv.cwd()
end

---@param dir string
---@return string[]
local function list_files(dir)
  local out
  if fn.executable('rg') == 1 then
    out = vim
      .system({ 'rg', '--files', '--hidden', '-g', '!.git' }, { cwd = dir, text = true })
      :wait()
  elseif fn.executable('git') == 1 and vim.fs.root(dir, '.git') then
    local argv = { 'git', 'ls-files', '--cached', '--others', '--exclude-standard' }
    out = vim.system(argv, { cwd = dir, text = true }):wait()
  end
  if out and out.code == 0 then
    return vim.split(vim.trim(out.stdout), '\n', { trimempty = true })
  end
  local files = {}
  for name, type in vim.fs.dir(dir, {
    depth = 20,
    skip = function(d)
      return not d:match('^%.git$') and not d:match('node_modules')
    end,
  }) do
    if type == 'file' then
      files[#files + 1] = name
      if #files > 50000 then
        break
      end
    end
  end
  return files
end

local function file_picker(dir)
  local items = {}
  for _, f in ipairs(list_files(dir)) do
    items[#items + 1] = { text = f, file = vim.fs.joinpath(dir, f) }
  end
  items_picker('Files: ' .. fn.fnamemodify(dir, ':~'), items)
end

cmd('file_picker', 'Open file picker', function()
  file_picker(root_dir())
end)
cmd('file_picker_in_current_directory', 'Open file picker at current working directory', function()
  file_picker(assert(vim.uv.cwd()))
end)
cmd('file_explorer', 'Open file explorer in workspace root', function()
  vim.cmd.edit(fn.fnameescape(root_dir()))
end)
cmd('file_explorer_in_current_buffer_directory', 'Open file explorer at buffer dir', function()
  local d = fn.expand('%:p:h')
  vim.cmd.edit(fn.fnameescape(d ~= '' and d or assert(vim.uv.cwd())))
end)

cmd('buffer_picker', 'Open buffer picker', function()
  local items = {}
  local cur = api.nvim_get_current_buf()
  for _, b in ipairs(api.nvim_list_bufs()) do
    if vim.bo[b].buflisted then
      local name = api.nvim_buf_get_name(b)
      local flags = (b == cur and '*' or ' ') .. (vim.bo[b].modified and '+' or ' ')
      items[#items + 1] = {
        text = ('%3d %s %s'):format(
          b,
          flags,
          name == '' and '[scratch]' or fn.fnamemodify(name, ':~:.')
        ),
        buf = b,
        lnum = api.nvim_buf_get_mark(b, '"')[1],
      }
    end
  end
  items_picker('Buffers', items)
end)

cmd('jumplist_picker', 'Open jumplist picker', function()
  local list = fn.getjumplist()[1]
  local items = {}
  for i = #list, 1, -1 do
    local j = list[i]
    if api.nvim_buf_is_valid(j.bufnr) then
      local line = api.nvim_buf_is_loaded(j.bufnr)
          and (api.nvim_buf_get_lines(j.bufnr, j.lnum - 1, j.lnum, false)[1] or '')
        or ''
      items[#items + 1] = {
        text = ('%s:%d %s'):format(
          fn.fnamemodify(api.nvim_buf_get_name(j.bufnr), ':~:.'),
          j.lnum,
          vim.trim(line)
        ),
        buf = j.bufnr,
        lnum = j.lnum,
        col = j.col + 1,
      }
    end
  end
  items_picker('Jumplist', items)
end)

cmd('changed_file_picker', 'Open changed file picker', function()
  local root = vim.fs.root(0, '.git') or vim.uv.cwd()
  local out = vim.system({ 'git', 'status', '--porcelain' }, { cwd = root, text = true }):wait()
  if out.code ~= 0 then
    notify('Not a git repository', vim.log.levels.WARN)
    return
  end
  local items = {}
  for _, l in ipairs(vim.split(out.stdout, '\n', { trimempty = true })) do
    local st, path = l:sub(1, 2), l:sub(4)
    path = path:gsub('^.* %-> ', '')
    items[#items + 1] = { text = st .. ' ' .. path, file = vim.fs.joinpath(root, path) }
  end
  items_picker('Changed files', items)
end)

local function qf_to_items(list)
  local items = {}
  for _, it in ipairs(list) do
    local fname = it.filename or (it.bufnr and api.nvim_buf_get_name(it.bufnr)) or ''
    items[#items + 1] = {
      text = ('%s:%d:%d %s'):format(
        fn.fnamemodify(fname, ':~:.'),
        it.lnum or 0,
        it.col or 0,
        vim.trim(it.text or '')
      ),
      file = fname,
      buf = it.bufnr,
      lnum = it.lnum,
      col = it.col,
    }
  end
  return items
end

--- Document symbols via tree-sitter (when no LSP).
local function ts_symbols()
  local ts = require('vim._core.helix_ts')
  if not ts.available() then
    notify('No language server or tree-sitter parser for this buffer', vim.log.levels.WARN)
    return
  end
  local items = {}
  local root = vim.treesitter.get_parser(0):parse()[1]:root()
  local buf = api.nvim_get_current_buf()
  local function visit(node)
    local t = node:type()
    if
      (t:find('function') or t:find('method') or t:find('class') or t:find('struct'))
      and not t:find('call')
      and (t:find('definition') or t:find('declaration') or t:find('item') or t:find('statement'))
    then
      local sr, sc = node:start()
      local name = node:field('name')[1]
      local label = name and vim.treesitter.get_node_text(name, buf) or vim.trim(sel.line(sr))
      items[#items + 1] =
        { text = ('%s  %s'):format(label, t), buf = buf, lnum = sr + 1, col = sc + 1 }
    end
    for child in node:iter_children() do
      if child:named() then
        visit(child)
      end
    end
  end
  visit(root)
  items_picker('Symbols', items)
end

cmd('symbol_picker', 'Open symbol picker', function()
  if not lsp_supports('textDocument/documentSymbol') then
    ts_symbols()
    return
  end
  vim.lsp.buf.document_symbol({
    on_list = function(opts)
      local items = {}
      for _, it in ipairs(opts.items or {}) do
        items[#items + 1] = {
          text = vim.trim(it.text or ''),
          file = it.filename,
          buf = it.bufnr,
          lnum = it.lnum,
          col = it.col,
        }
      end
      items_picker('Symbols', items)
    end,
  })
end)

cmd('workspace_symbol_picker', 'Open workspace symbol picker', function()
  if not lsp_supports('workspace/symbol') then
    notify('No configured language server supports workspace symbols', vim.log.levels.WARN)
    return
  end
  local buf = api.nvim_get_current_buf()
  require('vim._core.helix_picker').open({
    title = 'Workspace symbols',
    items = {},
    dynamic = function(q)
      local res = vim.lsp.buf_request_sync(buf, 'workspace/symbol', { query = q }, 2000) or {}
      local items = {}
      for id, r in pairs(res) do
        local client = vim.lsp.get_client_by_id(id)
        if r.result and client then
          local list = vim.lsp.util.symbols_to_items(r.result, buf, client.offset_encoding)
          vim.list_extend(items, qf_to_items(list))
        end
      end
      return items
    end,
  })
end)

cmd('diagnostics_picker', 'Open diagnostic picker', function()
  items_picker('Diagnostics', qf_to_items(vim.diagnostic.toqflist(vim.diagnostic.get(0))))
end)
cmd('workspace_diagnostics_picker', 'Open workspace diagnostic picker', function()
  items_picker('Workspace diagnostics', qf_to_items(vim.diagnostic.toqflist(vim.diagnostic.get())))
end)

cmd('hover', 'Show docs for item under cursor', function()
  sel.sync_cursor()
  vim.lsp.buf.hover()
end)
cmd('rename_symbol', 'Rename symbol', function()
  sel.sync_cursor()
  vim.lsp.buf.rename()
end)
cmd('code_action', 'Perform code action', function()
  local s = sel.primary()
  if sel.cmp(s.a, s.h) == 0 then
    vim.lsp.buf.code_action()
  else
    local f, t = sel.from(s), sel.to(s)
    vim.lsp.buf.code_action({
      range = { start = { f[1] + 1, f[2] }, ['end'] = { t[1] + 1, t[2] } },
    })
  end
end)

cmd('select_references_to_symbol_under_cursor', 'Select symbol references', function()
  if
    not lsp_supports('textDocument/documentHighlight')
    and not lsp_supports('textDocument/references')
  then
    notify('No configured language server supports references', vim.log.levels.WARN)
    return
  end
  sel.sync_cursor()
  local buf = api.nvim_get_current_buf()
  local method = lsp_supports('textDocument/documentHighlight') and 'textDocument/documentHighlight'
    or 'textDocument/references'
  local client = vim.lsp.get_clients({ bufnr = buf, method = method })[1]
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  ---@diagnostic disable-next-line: inject-field
  params.context = { includeDeclaration = true }
  local res = client:request_sync(method, params, 2000, buf)
  if not res or not res.result then
    return
  end
  local out = {}
  local uri = vim.uri_from_bufnr(buf)
  for _, loc in ipairs(res.result) do
    if not loc.uri or loc.uri == uri then
      local r = loc.range
      local sl = sel.line(r.start.line)
      local el = sel.line(r['end'].line)
      local sc = vim.str_byteindex(sl, client.offset_encoding, r.start.character, false)
      local ec = vim.str_byteindex(el, client.offset_encoding, r['end'].character, false)
      local a = { r.start.line, sc }
      local h = sel.prev({ r['end'].line, ec }) or a
      out[#out + 1] = { a = a, h = h }
    end
  end
  if #out > 0 then
    local cur = sel.primary().h
    local primary = 1
    for i, s in ipairs(out) do
      if sel.cmp(s.a, cur) <= 0 and sel.cmp(cur, s.h) <= 0 then
        primary = i
      end
    end
    sel.set(out, primary)
  end
end)

local function clipboard_paste(before)
  return function()
    paste(before, '+')
  end
end
cmd('paste_clipboard_after', 'Paste clipboard after selections', clipboard_paste(false))
cmd('paste_clipboard_before', 'Paste clipboard before selections', clipboard_paste(true))
cmd('yank_to_clipboard', 'Yank selections to clipboard', function()
  local vals = vim.tbl_map(sel.text, sel.get().sels)
  reg_write('+', vals)
  notify(('yanked %d selection%s to the clipboard'):format(#vals, #vals == 1 and '' or 's'))
end)
cmd('yank_main_selection_to_clipboard', 'Yank main selection to clipboard', function()
  reg_write('+', { sel.text(sel.primary()) })
  notify('yanked primary selection to the clipboard')
end)
cmd('replace_selections_with_clipboard', 'Replace selections by clipboard content', function()
  replace_with('+')
end)

cmd('global_search', 'Global search in workspace folder', function()
  local root = root_dir()
  local rg = fn.executable('rg') == 1
  require('vim._core.helix_picker').open({
    title = 'Global search: ' .. fn.fnamemodify(root, ':~'),
    items = {},
    dynamic = function(q)
      if q == '' then
        return {}
      end
      local argv = rg and { 'rg', '--vimgrep', '--smart-case', '-e', q }
        or { 'grep', '-rnI', '--exclude-dir=.git', '-e', q, '.' }
      local out = vim.system(argv, { cwd = root, text = true }):wait()
      local items = {}
      for _, l in ipairs(vim.split(out.stdout or '', '\n', { trimempty = true })) do
        local file, lnum, col, text
        if rg then
          file, lnum, col, text = l:match('^(.-):(%d+):(%d+):(.*)$')
        else
          file, lnum, text = l:match('^(.-):(%d+):(.*)$')
          col = 1
        end
        if file then
          file = file:gsub('^%./', '')
          items[#items + 1] = {
            text = ('%s:%s %s'):format(file, lnum, vim.trim(text)),
            file = vim.fs.joinpath(root, file),
            lnum = tonumber(lnum),
            col = tonumber(col),
          }
          if #items >= 2000 then
            break
          end
        end
      end
      return items
    end,
  })
end)

cmd('last_picker', 'Open last picker', function()
  require('vim._core.helix_picker').resume()
end)

cmd('command_palette', 'Open command palette', function()
  local items = {}
  for name, c in pairs(M.commands) do
    items[#items + 1] = {
      text = ('%-45s %s%s'):format(name, c.desc, c.keys and ('  [' .. c.keys .. ']') or ''),
      action = function()
        c.fn()
      end,
    }
  end
  table.sort(items, function(a, b)
    return a.text < b.text
  end)
  require('vim._core.helix_picker').open({ title = 'Command palette', items = items, preview = false })
end)

cmd('dap', 'Debug (experimental)', function()
  notify('Debugging (DAP) is not built in; install a DAP client plugin', vim.log.levels.WARN)
end)

local space_entries = {
  { 'f', 'file_picker', 'Open file picker at LSP workspace root' },
  { 'F', 'file_picker_in_current_directory' },
  { 'e', 'file_explorer' },
  { '.', 'file_explorer_in_current_buffer_directory' },
  { 'b', 'buffer_picker' },
  { 'j', 'jumplist_picker' },
  { 'g', 'changed_file_picker' },
  { 'G', 'dap' },
  { 'k', 'hover' },
  { 's', 'symbol_picker' },
  { 'S', 'workspace_symbol_picker' },
  { 'd', 'diagnostics_picker' },
  { 'D', 'workspace_diagnostics_picker' },
  { 'r', 'rename_symbol' },
  { 'a', 'code_action' },
  { 'h', 'select_references_to_symbol_under_cursor' },
  { "'", 'last_picker' },
  { 'w', prefix('Window', window_entries, false, '<Space> w'), 'Window mode' },
  { 'c', 'toggle_comments' },
  { 'C', 'toggle_block_comments' },
  { '<M-c>', 'toggle_line_comments' },
  { 'p', 'paste_clipboard_after' },
  { 'P', 'paste_clipboard_before' },
  { 'y', 'yank_to_clipboard' },
  { 'Y', 'yank_main_selection_to_clipboard' },
  { 'R', 'replace_selections_with_clipboard' },
  { '/', 'global_search' },
  { '?', 'command_palette' },
}

-- Unimpaired.

local function diag_jump(dir)
  return function()
    sel.sync_cursor()
    local s = sel.primary()
    local p = dir > 0 and sel.to(s) or sel.from(s)
    local d =
      vim.diagnostic.jump({ count = dir * count(), pos = { p[1] + 1, p[2] }, float = false })
    if d then
      local a = { d.lnum, d.col }
      local h = sel.prev({ d.end_lnum or d.lnum, d.end_col or d.col }) or a
      if sel.cmp(h, a) < 0 then
        h = a
      end
      sel.set({ { a = a, h = h } }, 1)
    else
      sel.reset_to_cursor()
    end
  end
end

cmd('goto_next_diag', 'Goto next diagnostic', diag_jump(1))
cmd('goto_prev_diag', 'Goto previous diagnostic', diag_jump(-1))
cmd('goto_first_diag', 'Goto first diagnostic', function()
  local ds = vim.diagnostic.get(0)
  table.sort(ds, function(a, b)
    return a.lnum < b.lnum or (a.lnum == b.lnum and a.col < b.col)
  end)
  if ds[1] then
    push_jump()
    sel.set({ { a = { ds[1].lnum, ds[1].col }, h = { ds[1].lnum, ds[1].col } } }, 1)
  end
end)
cmd('goto_last_diag', 'Goto last diagnostic', function()
  local ds = vim.diagnostic.get(0)
  table.sort(ds, function(a, b)
    return a.lnum < b.lnum or (a.lnum == b.lnum and a.col < b.col)
  end)
  local d = ds[#ds]
  if d then
    push_jump()
    sel.set({ { a = { d.lnum, d.col }, h = { d.lnum, d.col } } }, 1)
  end
end)

local function ts_goto(kind, forward)
  return function()
    local ts = require('vim._core.helix_ts')
    if not ts.available() then
      notify('no tree-sitter parser for this buffer', vim.log.levels.WARN)
      return
    end
    local function run()
      local n = count()
      motion(function(s)
        local r
        local p = forward and sel.to(s) or sel.from(s)
        for _ = 1, n do
          local nr = ts.goto_kind(p, kind, forward)
          if not nr then
            break
          end
          r, p = nr, nr.a
        end
        return r
      end)
    end
    last_motion = run
    run()
  end
end

for _, k in ipairs({
  { 'function', 'function' },
  { 'class', 'class' },
  { 'parameter', 'parameter' },
  { 'comment', 'comment' },
  { 'entry', 'entry' },
  { 'test', 'test' },
  { 'xml_element', 'xml' },
}) do
  cmd('goto_next_' .. k[1], 'Goto next ' .. k[1], ts_goto(k[2], true))
  cmd('goto_prev_' .. k[1], 'Goto previous ' .. k[1], ts_goto(k[2], false))
end

local function paragraph(forward)
  return function()
    local function run()
      local n = count()
      local lc = sel.line_count()
      motion(function(s)
        local r = s.h[1]
        local function blank(x)
          return sel.line(x):match('^%s*$') ~= nil
        end
        for _ = 1, n do
          if forward then
            -- Skip blank lines, then the paragraph, then trailing blanks.
            while r < lc - 1 and blank(r) do
              r = r + 1
            end
            while r < lc - 1 and not blank(r) do
              r = r + 1
            end
            while r < lc - 1 and blank(r + 1) do
              r = r + 1
            end
          else
            while r > 0 and blank(r - 1) do
              r = r - 1
            end
            if r > 0 then
              r = r - 1
            end
            while r > 0 and blank(r) do
              r = r - 1
            end
            while r > 0 and not blank(r - 1) do
              r = r - 1
            end
          end
        end
        if forward then
          return { a = { s.h[1], s.h[2] }, h = { r, #sel.line(r) } }
        end
        return { a = s.h, h = { r, 0 } }
      end)
    end
    last_motion = run
    run()
  end
end

cmd('goto_next_paragraph', 'Goto next paragraph', paragraph(true))
cmd('goto_prev_paragraph', 'Goto previous paragraph', paragraph(false))

--- Changed line ranges (0-indexed, inclusive) vs. git HEAD, or vs. the
--- other window in diff mode.
---@return {[1]: integer, [2]: integer}[]
local function hunks()
  local file = api.nvim_buf_get_name(0)
  local out = {}
  if vim.wo.diff then
    for r = 0, sel.line_count() - 1 do
      if fn.diff_hlID(r + 1, 1) > 0 then
        local last = out[#out]
        if last and last[2] == r - 1 then
          last[2] = r
        else
          out[#out + 1] = { r, r }
        end
      end
    end
    return out
  end
  if file == '' or fn.executable('git') == 0 then
    return out
  end
  local dir = fn.fnamemodify(file, ':h')
  local rel =
    vim.system({ 'git', 'ls-files', '--full-name', file }, { cwd = dir, text = true }):wait()
  if rel.code ~= 0 or vim.trim(rel.stdout) == '' then
    return out
  end
  local spec = 'HEAD:' .. vim.trim(rel.stdout)
  local head = vim.system({ 'git', 'show', spec }, { cwd = dir, text = true }):wait()
  if head.code ~= 0 then
    return out
  end
  local cur = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), '\n') .. '\n'
  local idx = vim.text.diff(head.stdout, cur, { result_type = 'indices' }) --[[@as integer[][] ]]
  for _, h in ipairs(idx) do
    local start, cnt = h[3], h[4]
    if cnt == 0 then
      out[#out + 1] = { math.max(0, start - 1), math.max(0, start - 1) }
    else
      out[#out + 1] = { start - 1, start + cnt - 2 }
    end
  end
  return out
end

local function hunk_sel(h)
  return { a = { h[1], 0 }, h = { h[2], #sel.line(h[2]) } }
end

local function goto_change(which)
  return function()
    local hs = hunks()
    if #hs == 0 then
      notify('No changes', vim.log.levels.WARN)
      return
    end
    local r = sel.primary().h[1]
    local target
    if which == 'first' then
      target = hs[1]
    elseif which == 'last' then
      target = hs[#hs]
    elseif which == 'next' then
      local n = count()
      for _, h in ipairs(hs) do
        if h[1] > r then
          n = n - 1
          target = h
          if n == 0 then
            break
          end
        end
      end
    else
      local n = count()
      for i = #hs, 1, -1 do
        if hs[i][2] < r then
          n = n - 1
          target = hs[i]
          if n == 0 then
            break
          end
        end
      end
    end
    if target then
      push_jump()
      local s = hunk_sel(target)
      if M.mode == 'select' then
        s.a = sel.primary().a
      end
      sel.set({ s }, 1)
    end
  end
end

cmd('goto_next_change', 'Goto next change', goto_change('next'))
cmd('goto_prev_change', 'Goto previous change', goto_change('prev'))
cmd('goto_first_change', 'Goto first change', goto_change('first'))
cmd('goto_last_change', 'Goto last change', goto_change('last'))

local function add_newline(below)
  return function()
    local n = count()
    local lines = {}
    for i = 1, n do
      lines[i] = ''
    end
    sel.track(function()
      local rows = {}
      for _, s in ipairs(sel.get().sels) do
        rows[#rows + 1] = below and sel.to(s)[1] + 1 or sel.from(s)[1]
      end
      table.sort(rows)
      for i = #rows, 1, -1 do
        if rows[i] ~= rows[i + 1] then
          api.nvim_buf_set_lines(0, rows[i], rows[i], false, lines)
        end
      end
    end)
  end
end

cmd('add_newline_below', 'Add newline below', add_newline(true))
cmd('add_newline_above', 'Add newline above', add_newline(false))

local next_entries = {
  { 'd', 'goto_next_diag' },
  { 'D', 'goto_last_diag' },
  { 'f', 'goto_next_function' },
  { 't', 'goto_next_class' },
  { 'a', 'goto_next_parameter' },
  { 'c', 'goto_next_comment' },
  { 'e', 'goto_next_entry' },
  { 'T', 'goto_next_test' },
  { 'p', 'goto_next_paragraph' },
  { 'g', 'goto_next_change' },
  { 'G', 'goto_last_change' },
  { 'x', 'goto_next_xml_element' },
  { '<Space>', 'add_newline_below' },
}
local prev_entries = {
  { 'd', 'goto_prev_diag' },
  { 'D', 'goto_first_diag' },
  { 'f', 'goto_prev_function' },
  { 't', 'goto_prev_class' },
  { 'a', 'goto_prev_parameter' },
  { 'c', 'goto_prev_comment' },
  { 'e', 'goto_prev_entry' },
  { 'T', 'goto_prev_test' },
  { 'p', 'goto_prev_paragraph' },
  { 'g', 'goto_prev_change' },
  { 'G', 'goto_first_change' },
  { 'x', 'goto_prev_xml_element' },
  { '<Space>', 'add_newline_above' },
}

-- Mode switching.

cmd('select_mode', 'Enter selection extend mode', function()
  if M.mode == 'select' then
    M.mode = 'normal'
  else
    M.mode = 'select'
  end
  vim.cmd.redrawstatus()
end)

cmd('normal_mode', 'Enter normal mode', function()
  if M.mode == 'select' then
    M.mode = 'normal'
    vim.cmd.redrawstatus()
  end
  close_info()
end)

cmd('select_register', 'Select register', function()
  local entries = {}
  for _, r in ipairs({ '"', '/', '+', '*', '_', '#', '.', '%', '@' }) do
    local v = reg_read(r)[1]
    entries[#entries + 1] = { r, v and v:gsub('\n', '⏎'):sub(1, 40) or '' }
  end
  show_info('Registers', entries)
  local k = getkey()
  close_info()
  if k then
    M.reg_pending = k
  end
end)

cmd('command_mode', 'Enter command mode', function()
  api.nvim_feedkeys(':', 'ni', false)
end)

-- }}}

-- Insert/prompt helpers {{{

local function insert_delete_word_forward()
  local c = api.nvim_win_get_cursor(0)
  local r, col = c[1] - 1, c[2]
  local l = sel.line(r)
  if col >= #l then
    if r < sel.line_count() - 1 then
      api.nvim_buf_set_text(0, r, col, r + 1, 0, { '' })
    end
    return
  end
  local e = col
  while e < #l and l:sub(e + 1, e + 1):match('%s') do
    e = e + 1
  end
  local cls = e < #l and sel.class(l:sub(e + 1, e + sel.charlen(l, e)))
  while e < #l and sel.class(l:sub(e + 1, e + sel.charlen(l, e))) == cls do
    e = e + sel.charlen(l, e)
  end
  api.nvim_buf_set_text(0, r, col, r, e, { '' })
end

local function insert_kill_to_line_end()
  local c = api.nvim_win_get_cursor(0)
  local l = sel.line(c[1] - 1)
  if c[2] >= #l then
    if c[1] < sel.line_count() then
      api.nvim_buf_set_text(0, c[1] - 1, c[2], c[1], 0, { '' })
    end
  else
    api.nvim_buf_set_text(0, c[1] - 1, c[2], c[1] - 1, #l, { '' })
  end
end

local function insert_kill_to_line_start()
  local c = api.nvim_win_get_cursor(0)
  if c[2] == 0 then
    if c[1] > 1 then
      local pl = sel.line(c[1] - 2)
      api.nvim_buf_set_text(0, c[1] - 2, #pl, c[1] - 1, 0, { '' })
      api.nvim_win_set_cursor(0, { c[1] - 1, #pl })
    end
    return
  end
  local l = sel.line(c[1] - 1)
  local ind = #(l:match('^%s*'))
  local start = c[2] > ind and ind or 0
  api.nvim_buf_set_text(0, c[1] - 1, start, c[1] - 1, c[2], { '' })
  api.nvim_win_set_cursor(0, { c[1], start })
end

local function cmdline_delete_word_forward()
  local l, p = fn.getcmdline(), fn.getcmdpos()
  local e = p
  while e <= #l and l:sub(e, e):match('%s') do
    e = e + 1
  end
  local cls = e <= #l and sel.class(l:sub(e, e))
  while e <= #l and sel.class(l:sub(e, e)) == cls do
    e = e + 1
  end
  fn.setcmdline(l:sub(1, p - 1) .. l:sub(e), p)
end

local function cmdline_kill_to_end()
  local l, p = fn.getcmdline(), fn.getcmdpos()
  fn.setcmdline(l:sub(1, p - 1), p)
end

-- }}}

-- Keymaps {{{

--- Normal-mode (and select-mode) keys → command names (or functions).
---@type {[1]: string|string[], [2]: string|fun()}[]
local normal_keys = {
  -- Movement
  { { 'h', '<Left>' }, 'move_char_left' },
  { { 'j', '<Down>' }, 'move_visual_line_down' },
  { { 'k', '<Up>' }, 'move_visual_line_up' },
  { { 'l', '<Right>' }, 'move_char_right' },
  { 'w', 'move_next_word_start' },
  { 'b', 'move_prev_word_start' },
  { 'e', 'move_next_word_end' },
  { 'W', 'move_next_long_word_start' },
  { 'B', 'move_prev_long_word_start' },
  { 'E', 'move_next_long_word_end' },
  { 't', 'find_till_char' },
  { 'f', 'find_next_char' },
  { 'T', 'till_prev_char' },
  { 'F', 'find_prev_char' },
  { 'G', 'goto_line' },
  { '<M-.>', 'repeat_last_motion' },
  { '<Home>', 'goto_line_start' },
  { '<End>', 'goto_line_end' },
  { { '<C-b>', '<PageUp>' }, 'page_up' },
  { { '<C-f>', '<PageDown>' }, 'page_down' },
  { '<C-u>', 'page_cursor_half_up' },
  { '<C-d>', 'page_cursor_half_down' },
  { { '<C-i>', '<Tab>' }, 'jump_forward' },
  { '<C-o>', 'jump_backward' },
  { '<C-s>', 'save_selection' },
  -- Changes
  { 'r', 'replace' },
  { 'R', 'replace_with_yanked' },
  { '~', 'switch_case' },
  { '`', 'switch_to_lowercase' },
  { '<M-`>', 'switch_to_uppercase' },
  { 'i', 'insert_mode' },
  { 'a', 'append_mode' },
  { 'I', 'insert_at_line_start' },
  { 'A', 'insert_at_line_end' },
  { 'o', 'open_below' },
  { 'O', 'open_above' },
  { '.', 'repeat_last_insert' },
  { 'u', 'undo' },
  { 'U', 'redo' },
  { '<M-u>', 'earlier' },
  { '<M-U>', 'later' },
  { 'y', 'yank' },
  { 'p', 'paste_after' },
  { 'P', 'paste_before' },
  { '"', 'select_register' },
  { '>', 'indent' },
  { '<', 'unindent' },
  { '=', 'format_selections' },
  { 'd', 'delete_selection' },
  { '<M-d>', 'delete_selection_noyank' },
  { 'c', 'change_selection' },
  { '<M-c>', 'change_selection_noyank' },
  { '<C-a>', 'increment' },
  { '<C-x>', 'decrement' },
  { 'Q', 'record_macro' },
  { 'q', 'replay_macro' },
  { '<C-z>', 'suspend' },
  -- Shell
  { '|', 'shell_pipe' },
  { '<M-|>', 'shell_pipe_to' },
  { '!', 'shell_insert_output' },
  { '<M-!>', 'shell_append_output' },
  { '$', 'shell_keep_pipe' },
  -- Selection manipulation
  { 's', 'select_regex' },
  { 'S', 'split_selection' },
  { '<M-s>', 'split_selection_on_newline' },
  { '<M-->', 'merge_selections' },
  { '<M-_>', 'merge_consecutive_selections' },
  { '&', 'align_selections' },
  { '_', 'trim_selections' },
  { ';', 'collapse_selection' },
  { '<M-;>', 'flip_selections' },
  { '<M-:>', 'ensure_selections_forward' },
  { ',', 'keep_primary_selection' },
  { '<M-,>', 'remove_primary_selection' },
  { 'C', 'copy_selection_on_next_line' },
  { '<M-C>', 'copy_selection_on_prev_line' },
  { '(', 'rotate_selections_backward' },
  { ')', 'rotate_selections_forward' },
  { '<M-(>', 'rotate_selection_contents_backward' },
  { '<M-)>', 'rotate_selection_contents_forward' },
  { '%', 'select_all' },
  { 'x', 'extend_line_below' },
  { 'X', 'extend_to_line_bounds' },
  { '<M-x>', 'shrink_to_line_bounds' },
  { 'J', 'join_selections' },
  { '<M-J>', 'join_selections_space' },
  { 'K', 'keep_selections' },
  { '<M-K>', 'remove_selections' },
  { '<C-c>', 'toggle_comments' },
  { { '<M-o>', '<M-Up>' }, 'expand_selection' },
  { { '<M-i>', '<M-Down>' }, 'shrink_selection' },
  { { '<M-p>', '<M-Left>' }, 'select_prev_sibling' },
  { { '<M-n>', '<M-Right>' }, 'select_next_sibling' },
  { '<M-a>', 'select_all_siblings' },
  { { '<M-I>', '<M-S-Down>' }, 'select_all_children' },
  { '<M-e>', 'move_parent_node_end' },
  { '<M-b>', 'move_parent_node_start' },
  -- Search
  { '/', 'search' },
  { '?', 'rsearch' },
  { 'n', 'search_next' },
  { 'N', 'search_prev' },
  { '*', 'search_selection_detect_word_boundaries' },
  { '<M-*>', 'search_selection' },
  -- Minor modes
  { 'v', 'select_mode' },
  { 'g', prefix('Goto', goto_entries, false, 'g') },
  { 'm', prefix('Match', match_entries, false, 'm') },
  { ':', 'command_mode' },
  { 'z', prefix('View', view_entries, false, 'z') },
  { 'Z', prefix('View (sticky)', view_entries, true) },
  { '<C-w>', prefix('Window', window_entries, false, '<C-w>') },
  { '<Space>', prefix('Space', space_entries, false, '<Space>') },
  { ']', prefix('Right bracket', next_entries, false, ']') },
  { '[', prefix('Left bracket', prev_entries, false, '[') },
  { '<Esc>', 'normal_mode' },
}

--- Vim keys with no Helix binding: disabled so they don't do surprising
--- things (Helix ignores unbound keys).
local unbound = {
  'D',
  'H',
  'L',
  'M',
  'Y',
  '-',
  '+',
  '^',
  '#',
  '@',
  '{',
  '}',
  "'",
  '\\',
  '0',
  '<C-r>',
  '<C-v>',
  '<C-q>',
}

M.keymaps = normal_keys

--- Wraps a command so errors are reported instead of thrown.
local function wrap(f)
  return function()
    finish_insert()
    local ok, err = xpcall(f, debug.traceback)
    if not ok then
      close_info()
      sel.busy = false
      M.internal_visual = false
      notify('helix: ' .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

--- Nvim default mappings that would shadow Helix keys (prefix modes).
local default_maps = {
  'gc',
  'gcc',
  'gO',
  'gx',
  'gra',
  'gri',
  'grn',
  'grr',
  'grt',
  'grx',
  '<C-W>d',
  '<C-W><C-D>',
  '[ ',
  '] ',
  '[d',
  ']d',
  '[D',
  ']D',
  '[a',
  ']a',
  '[A',
  ']A',
  '[b',
  ']b',
  '[B',
  ']B',
  '[l',
  ']l',
  '[L',
  ']L',
  '[q',
  ']q',
  '[Q',
  ']Q',
  '[t',
  ']t',
  '[T',
  ']T',
  '[<C-L>',
  ']<C-L>',
  '[<C-Q>',
  ']<C-Q>',
  '[<C-T>',
  ']<C-T>',
  '[[',
  ']]',
}

--- Mappings set by Helix mode, as {mode, lhs}, removed by |M.disable()|.
local installed = {} ---@type {[1]: string, [2]: string}[]
--- Default mappings removed by Helix mode, restored by |M.disable()|.
local removed = {} ---@type table[]

---@param modes string|string[]
---@param lhss string|string[]
local function kset(modes, lhss, rhs, o)
  vim.keymap.set(modes, lhss, rhs, o)
  for _, m in ipairs(type(modes) == 'table' and modes or { modes }) do
    for _, l in ipairs(type(lhss) == 'table' and lhss or { lhss }) do
      installed[#installed + 1] = { m, l }
    end
  end
end

local function set_keymaps()
  local opts = { nowait = true }
  for _, lhs in ipairs(default_maps) do
    for _, mode in ipairs({ 'n', 'x' }) do
      local m = fn.maparg(lhs, mode, false, true)
      if not vim.tbl_isempty(m) and not (m.desc or ''):match('^helix') then
        removed[#removed + 1] = m
        pcall(vim.keymap.del, mode, lhs)
      end
    end
  end
  for _, lhs in ipairs(unbound) do
    kset('n', lhs, '<Nop>', { desc = 'helix: unbound' })
  end
  for _, m in ipairs(normal_keys) do
    local keys = type(m[1]) == 'table' and m[1] or { m[1] }
    local rhs = m[2]
    local desc
    if type(rhs) == 'string' then
      local c = M.commands[rhs]
      assert(c, 'unknown helix command: ' .. rhs)
      c.keys = (c.keys and (c.keys .. ', ') or '') .. table.concat(keys --[[@as string[] ]], ', ')
      desc = 'helix: ' .. c.desc
      rhs = c.fn
    else
      desc = 'helix: ' .. tostring(keys[1]) .. ' mode'
    end
    for _, lhs in ipairs(keys --[[@as string[] ]]) do
      kset('n', lhs, wrap(rhs), vim.tbl_extend('force', opts, { desc = desc }))
    end
  end

  -- Insert mode.
  kset('i', '<C-s>', '<C-g>u', { desc = 'helix: commit undo checkpoint' })
  kset('i', '<C-x>', function()
    if vim.bo.omnifunc ~= '' then
      return '<C-x><C-o>'
    end
    return '<C-n>'
  end, { expr = true, desc = 'helix: completion' })
  kset('i', '<M-BS>', '<C-g>u<C-w>', { desc = 'helix: delete previous word' })
  kset(
    'i',
    { '<M-d>', '<M-Del>' },
    insert_delete_word_forward,
    { desc = 'helix: delete next word' }
  )
  kset('i', '<C-u>', insert_kill_to_line_start, { desc = 'helix: kill to line start' })
  kset('i', '<C-k>', insert_kill_to_line_end, { desc = 'helix: kill to line end' })
  kset('i', '<C-d>', '<Del>', { desc = 'helix: delete next char' })
  kset('i', '<S-BS>', '<BS>', { desc = 'helix: delete previous char' })
  kset('i', '<S-Tab>', function()
    if fn.pumvisible() == 1 then
      return '<C-p>'
    end
    return '<C-v><Tab>'
  end, { expr = true, desc = 'helix: insert tab / previous completion' })
  kset('i', '<Tab>', function()
    if fn.pumvisible() == 1 then
      return '<C-n>'
    end
    return '<Tab>'
  end, { expr = true, desc = 'helix: smart tab / next completion' })
  kset('i', '<C-c>', function()
    if fn.pumvisible() == 1 then
      return '<C-e>'
    end
    return '<Esc>'
  end, { expr = true, desc = 'helix: reject completion' })

  -- Command-line (prompt) mode.
  kset('c', { '<M-b>', '<C-Left>' }, '<S-Left>', { desc = 'helix: backward a word' })
  kset('c', '<C-b>', '<Left>', { desc = 'helix: backward a char' })
  kset('c', { '<M-f>', '<C-Right>' }, '<S-Right>', { desc = 'helix: forward a word' })
  kset('c', '<C-f>', '<Right>', { desc = 'helix: forward a char' })
  kset('c', '<C-a>', '<Home>', { desc = 'helix: move prompt start' })
  kset('c', { '<M-BS>', '<C-BS>' }, '<C-w>', { desc = 'helix: delete previous word' })
  kset(
    'c',
    { '<M-d>', '<M-Del>', '<C-Del>' },
    cmdline_delete_word_forward,
    { desc = 'helix: delete next word' }
  )
  kset('c', '<C-k>', cmdline_kill_to_end, { desc = 'helix: delete to end of line' })
  kset('c', '<C-d>', '<Del>', { desc = 'helix: delete next char' })
  kset('c', '<S-BS>', '<BS>', { desc = 'helix: delete previous char' })
  kset('c', '<C-s>', '<C-r><C-w>', { desc = 'helix: insert word under cursor' })
end

-- }}}

-- Autocommands & setup {{{

--- Mode name for the statusline.
function M.mode_name()
  local m = api.nvim_get_mode().mode
  if m:sub(1, 1) == 'i' then
    return 'INS'
  elseif m:sub(1, 1) == 'c' then
    return M.mode == 'select' and 'SEL' or 'NOR'
  elseif m:sub(1, 1) == 't' then
    return 'TER'
  end
  return M.mode == 'select' and 'SEL' or 'NOR'
end

local function set_highlights()
  local function link(name, to)
    api.nvim_set_hl(0, name, { link = to, default = true })
  end
  link('HelixSelection', 'Visual')
  link('HelixSelectionPrimary', 'Visual')
  link('HelixCursor', 'MCursor')
  link('HelixJumpLabel', 'Search')
  link('HelixModeNormal', 'StatusLine')
end

local function create_autocmds()
  local group = api.nvim_create_augroup('nvim.helix', { clear = true })
  api.nvim_create_autocmd('CursorMoved', {
    group = group,
    callback = function(ev)
      if sel.busy or ins or leaving or vim.v.cascading == 1 then
        return
      end
      local st = sel.states[ev.buf]
      if not st then
        sel.get(ev.buf)
        sel.render()
        return
      end
      local h = st.sels[st.primary].h
      local c = api.nvim_win_get_cursor(0)
      if c[1] - 1 ~= h[1] or c[2] ~= h[2] then
        sel.reset_to_cursor()
      end
    end,
  })
  api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
    group = group,
    callback = function(ev)
      local st = sel.states[ev.buf]
      if st then
        local c = api.nvim_win_get_cursor(0)
        local h = st.sels[st.primary].h
        if c[1] - 1 ~= h[1] or c[2] ~= h[2] then
          sel.reset_to_cursor()
          return
        end
      end
      sel.render(ev.buf)
    end,
  })
  api.nvim_create_autocmd({ 'TextChanged' }, {
    group = group,
    callback = function(ev)
      local st = sel.states[ev.buf]
      if st and not ins then
        local new = {}
        for i, s in ipairs(st.sels) do
          new[i] = { a = sel.clamp(s.a), h = sel.clamp(s.h) }
        end
        st.sels = new
        sel.render(ev.buf)
      end
      if vim.bo[ev.buf].buftype == '' then
        for i = #last_modified, 1, -1 do
          if last_modified[i] == ev.buf then
            table.remove(last_modified, i)
          end
        end
        last_modified[#last_modified + 1] = ev.buf
      end
    end,
  })
  local insert_buf ---@type integer?
  api.nvim_create_autocmd('InsertEnter', {
    group = group,
    callback = function(ev)
      insert_buf = ev.buf
      api.nvim_buf_clear_namespace(ev.buf, sel.ns, 0, -1)
      if not ins then
        -- Entered Insert mode by other means (e.g. a plugin): track the cursor.
        sel.get(ev.buf)
        recording_keys = nil
      end
    end,
  })
  api.nvim_create_autocmd('InsertLeave', {
    group = group,
    callback = function(ev)
      if ins then
        leaving, ins = ins, nil
        vim.schedule(finish_insert)
      elseif ev.buf ~= insert_buf then
        -- Insert mode ended in another buffer (e.g. a closed picker prompt).
        sel.render(ev.buf)
      else
        sel.states[ev.buf] = nil
        vim.schedule(function()
          if api.nvim_get_current_buf() == ev.buf and not api.nvim_get_mode().mode:match('^i') then
            sel.reset_to_cursor()
          end
        end)
      end
    end,
  })
  api.nvim_create_autocmd('ModeChanged', {
    group = group,
    pattern = '*:[vV\22]*',
    callback = function()
      if M.internal_visual then
        return
      end
      -- Visual mode entered by other means (mouse, plugins): convert it to a
      -- selection.
      vim.schedule(function()
        local mode = api.nvim_get_mode().mode
        if not mode:match('^[vV\22]') or M.internal_visual then
          return
        end
        local v, c = fn.getpos('v'), fn.getpos('.')
        local a = { v[2] - 1, v[3] - 1 }
        local h = { c[2] - 1, c[3] - 1 }
        if mode == 'V' then
          if sel.cmp(a, h) <= 0 then
            a, h = { a[1], 0 }, { h[1], #sel.line(h[1]) }
          else
            a, h = { a[1], #sel.line(a[1]) }, { h[1], 0 }
          end
        end
        api.nvim_feedkeys(vim.keycode('<Esc>'), 'n', false)
        vim.schedule(function()
          sel.set({ { a = a, h = h } }, 1)
        end)
      end)
    end,
  })
  api.nvim_create_autocmd({ 'BufWipeout' }, {
    group = group,
    callback = function(ev)
      sel.states[ev.buf] = nil
    end,
  })
  api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_highlights })
  vim.on_key(function(_, typed)
    if recording_keys and typed and typed ~= '' and api.nvim_get_mode().mode:match('^i') then
      if typed == '\27' then
        return
      end
      recording_keys[#recording_keys + 1] = typed
    end
  end, insert_ns)
end

--- Enables Helix mode.
---@param opts? {statusline?: boolean}
local helix_stl = "%{v:lua.require('vim._core.helix').mode_name()} "
local added_onemore = false

--- Enables Helix mode. Called when 'helix' is set (and at startup).
function M.enable()
  if M.enabled then
    return
  end
  M.enabled = true
  M.mode = 'normal'
  -- Selections can include the newline at the end of a line.
  if not vim.o.virtualedit:find('onemore') and not vim.o.virtualedit:find('all') then
    vim.opt.virtualedit:append('onemore')
    added_onemore = true
  end
  set_highlights()
  set_keymaps()
  create_autocmds()
  -- Show the mode (NOR, SEL, INS) in the default statusline, like Helix.
  local default = api.nvim_get_option_info2('statusline', {}).default
  if vim.o.statusline == default then
    vim.o.statusline = helix_stl .. default
  end
  if vim.v.vim_did_enter == 1 then
    sel.reset_to_cursor()
  end
end

--- Called when 'helix' is set.
---@param on boolean
function M.sync(on)
  if on then
    M.enable()
  else
    M.disable()
  end
end

--- Disables Helix mode, restoring the Vim keys. Called when 'helix' is reset.
function M.disable()
  if not M.enabled then
    return
  end
  M.enabled = false
  M.mode = 'normal'
  M.reg_pending = nil
  close_info()
  for i = #installed, 1, -1 do
    pcall(vim.keymap.del, installed[i][1], installed[i][2])
  end
  installed = {}
  for _, m in ipairs(removed) do
    pcall(fn.mapset, m)
  end
  removed = {}
  pcall(api.nvim_del_augroup_by_name, 'nvim.helix')
  vim.on_key(nil, insert_ns)
  if added_onemore then
    vim.opt.virtualedit:remove('onemore')
    added_onemore = false
  end
  if vim.o.statusline:sub(1, #helix_stl) == helix_stl then
    vim.o.statusline = vim.o.statusline:sub(#helix_stl + 1)
  end
  for buf in pairs(sel.states) do
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_clear_namespace(buf, sel.ns, 0, -1)
    end
  end
  sel.states = {}
end

-- }}}

M.sel = sel
M.regs = regs
M.reg_read = reg_read
M.reg_write = reg_write

return M
