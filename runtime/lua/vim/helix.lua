--- @brief
--- Public API of |helix-mode|, for configs and plugins: read and change the
--- selections, and adapt Vim-style plugin features (cursor motions, operators,
--- text objects, pickers) to the Helix "selection first" model.
---
--- Positions are `{row, col}`, 0-indexed, `col` a byte index (|api-indexing|).
--- A selection is `{ anchor = pos, head = pos }`, both ends inclusive; the head
--- is the cursor. `col` equal to the line length addresses the line's newline.
---
--- See |helix-api| for recipes.

local api = vim.api

local M = {}

local function core()
  return require('vim._core.helix')
end

local function sel()
  return require('vim._core.helix_sel')
end

---@class vim.helix.Pos
---@field [1] integer row (0-indexed)
---@field [2] integer byte column (0-indexed)

---@class vim.helix.Selection
---@field anchor vim.helix.Pos
---@field head vim.helix.Pos

---@class vim.helix.Range
---@field start vim.helix.Pos first char (inclusive)
---@field end_ vim.helix.Pos last char (inclusive)
---@field linewise boolean whole lines (start at col 0, end at a newline)

---@param s nvim.helix.Sel
---@return vim.helix.Selection
local function export(s)
  return { anchor = { s.a[1], s.a[2] }, head = { s.h[1], s.h[2] } }
end

---@param s vim.helix.Selection
---@return nvim.helix.Sel
local function import(s)
  vim.validate('selection.anchor', s.anchor, 'table')
  vim.validate('selection.head', s.head, 'table')
  return { a = { s.anchor[1], s.anchor[2] }, h = { s.head[1], s.head[2] } }
end

---@param s nvim.helix.Sel
---@return vim.helix.Range
local function to_range(s)
  local S = sel()
  local f, t = S.from(s), S.to(s)
  return {
    start = { f[1], f[2] },
    end_ = { t[1], t[2] },
    linewise = f[2] == 0 and t[2] >= #S.line(t[1]),
  }
end

--- Whether Helix mode is enabled (the 'helix' option).
---@return boolean
function M.enabled()
  return core().enabled
end

--- Current Helix mode.
---@return 'normal'|'select'|'insert'
function M.mode()
  if api.nvim_get_mode().mode:match('^[iR]') then
    return 'insert'
  end
  return core().mode
end

--- Sets the Helix mode.
---@param mode 'normal'|'select'
function M.set_mode(mode)
  vim.validate('mode', mode, function(m)
    return m == 'normal' or m == 'select'
  end, "'normal' or 'select'")
  core().set_mode(mode)
end

--- Gets the selections of the current buffer.
---@return vim.helix.Selection[] selections In buffer order.
---@return integer primary Index of the primary selection (its head is the cursor).
function M.get_selections()
  local st = sel().get()
  return vim.tbl_map(export, st.sels), st.primary
end

--- Sets the selections of the current buffer. Overlapping selections are
--- merged; the cursor moves to the primary head.
---@param selections vim.helix.Selection[]
---@param primary? integer Index of the primary selection (default: last).
function M.set_selections(selections, primary)
  vim.validate('selections', selections, 'table')
  if #selections == 0 then
    return
  end
  sel().set(vim.tbl_map(import, selections), primary)
end

--- Gets the text of each selection (in buffer order).
---@return string[]
function M.get_text()
  local S = sel()
  return vim.tbl_map(S.text, S.get().sels)
end

--- Adapts a cursor motion (a jump/search/"go to" function of a plugin) to
--- Helix: after `fn` moves the cursor, the result becomes a selection, like
--- Helix's own motions. In select mode (|helix-v|) it extends the selections.
---
--- Works with synchronous motions (most jump plugins read keys with
--- |getcharstr()|) and asynchronous ones (the next cursor move is used). If
--- the plugin leaves a Visual selection, that becomes the selection.
---
--- Example: >lua
---     vim.keymap.set('n', '<leader>j', vim.helix.motion(function()
---       require('hop').hint_words()
---     end))
--- <
---@param fn fun() Moves the cursor.
---@param opts? {range?: boolean} range: select from the old cursor to the new
---  one (like `f`) instead of collapsing to the target.
---@return fun() # Mapping callback.
function M.motion(fn, opts)
  vim.validate('fn', fn, 'function')
  opts = opts or {}
  return core()._wrap(function()
    local H, S = core(), sel()
    local st = S.get()
    local before = vim.deepcopy(st.sels[st.primary])
    local buf = api.nvim_get_current_buf()
    S.sync_cursor()
    local tick = vim.b.changedtick
    local vstart, vend = vim.fn.getpos("'<"), vim.fn.getpos("'>")

    local function apply()
      if api.nvim_get_current_buf() ~= buf then
        S.reset_to_cursor()
        return
      end
      local mode = api.nvim_get_mode().mode
      local p ---@type nvim.helix.Pos
      local a ---@type nvim.helix.Pos?
      if mode:match('^[vV\22]') then
        -- The plugin made a Visual selection: use it.
        local v, c = vim.fn.getpos('v'), vim.fn.getpos('.')
        a, p = { v[2] - 1, v[3] - 1 }, { c[2] - 1, c[3] - 1 }
        if mode == 'V' then
          if S.cmp(a, p) <= 0 then
            a, p = { a[1], 0 }, { p[1], #S.line(p[1]) }
          else
            a, p = { a[1], #S.line(a[1]) }, { p[1], 0 }
          end
        end
        H.internal_visual = true
        vim.cmd('normal! \27')
        H.internal_visual = false
      elseif
        not vim.deep_equal(vim.fn.getpos("'<"), vstart)
        or not vim.deep_equal(vim.fn.getpos("'>"), vend)
      then
        -- The plugin made (and ended) a Visual selection, e.g. via :normal.
        local v1, v2 = vim.fn.getpos("'<"), vim.fn.getpos("'>")
        a, p = { v1[2] - 1, v1[3] - 1 }, S.clamp({ v2[2] - 1, v2[3] - 1 })
        if vim.fn.visualmode() == 'V' then
          a, p = { a[1], 0 }, { p[1], #S.line(p[1]) }
        end
      else
        local c = api.nvim_win_get_cursor(0)
        p = { c[1] - 1, c[2] }
      end
      if H.mode == 'select' then
        a = before.a
      elseif not a then
        a = (opts.range and vim.b.changedtick == tick) and before.h or p
      end
      S.set({ { a = a, h = p } }, 1)
    end

    S.busy = true
    local ok, err = pcall(fn)
    S.busy = false
    if not ok then
      error(err, 0)
    end
    local c = api.nvim_win_get_cursor(0)
    local moved = api.nvim_get_current_buf() ~= buf
      or c[1] - 1 ~= before.h[1]
      or c[2] ~= before.h[2]
      or api.nvim_get_mode().mode:match('^[vV\22]')
      or not vim.deep_equal(vim.fn.getpos("'<"), vstart)
    if moved then
      apply()
    else
      -- Asynchronous motion: apply at the next cursor move.
      api.nvim_create_autocmd({ 'CursorMoved', 'BufEnter' }, {
        once = true,
        callback = function()
          vim.schedule(apply)
        end,
      })
    end
  end)
end

--- Adapts a Vim operator to Helix: the returned function applies it to every
--- selection (last first), keeping the selections on the changed text.
---
--- `op` is either:
--- - Keys of a Visual-mode command or mapping (e.g. `"gc"`, `"U"`, or a
---   plugin's |:xmap| like `"S"` of nvim-surround). They run with mappings
---   enabled, on each selection made Visual (linewise if it covers whole
---   lines).
--- - A function receiving the |vim.helix.Range| of each selection; it may edit
---   the buffer.
---
--- Example: >lua
---     -- Use a plugin's Visual "sort" mapping on all selections.
---     vim.keymap.set('n', 'gs', vim.helix.operator('<Plug>(SortVisual)'))
--- <
---@param op string|fun(range: vim.helix.Range)
---@param opts? {linewise?: boolean} Force linewise (true) or charwise (false)
---  Visual mode (default: detect).
---@return fun() # Mapping callback.
function M.operator(op, opts)
  vim.validate('op', op, { 'string', 'function' })
  opts = opts or {}
  return core()._wrap(function()
    local H, S = core(), sel()
    S.transform(function(s)
      local range = to_range(s)
      local tick = vim.b.changedtick
      if type(op) == 'function' then
        op(range)
      else
        local linewise = opts.linewise
        if linewise == nil then
          linewise = range.linewise
        end
        local f, t = range.start, range.end_
        local tc = math.max(0, math.min(t[2], #S.line(t[1]) - 1))
        H.internal_visual = true
        S.busy = true
        local ok, err = pcall(function()
          vim.cmd('silent normal! ' .. (linewise and 'V' or 'v') .. '\27')
          vim.fn.setpos("'<", { 0, f[1] + 1, f[2] + 1, 0 })
          vim.fn.setpos("'>", { 0, t[1] + 1, tc + 1, 0 })
          vim.cmd('normal ' .. vim.keycode('<Plug>(helix-reselect)' .. op))
          if api.nvim_get_mode().mode:match('^[vV\22]') then
            vim.cmd('normal! \27')
          end
        end)
        H.internal_visual = false
        S.busy = false
        if not ok then
          error(err, 0)
        end
      end
      if vim.b.changedtick == tick then
        return s
      end
      -- Select the changed text ('[ and '] marks).
      local m1, m2 = api.nvim_buf_get_mark(0, '['), api.nvim_buf_get_mark(0, ']')
      if m1[1] == 0 or m2[1] == 0 then
        return nil
      end
      local a = S.clamp({ m1[1] - 1, m1[2] })
      local h = S.clamp({ m2[1] - 1, m2[2] })
      if range.linewise then
        a, h = { a[1], 0 }, { h[1], #S.line(h[1]) }
      end
      if S.cmp(h, a) < 0 then
        h = a
      end
      return { a = a, h = h }
    end)
  end)
end

--- Adds a text object to match mode: `m a {key}` / `m i {key}` (see
--- |helix-match|). Each side is either the keys of a Vim text object
--- (Operator-pending/Visual mapping, e.g. `"af"` from a tree-sitter
--- textobjects plugin) or a function that gets the |vim.helix.Range| of a
--- selection and returns the new range (or nil).
---
--- Example: >lua
---     vim.helix.textobject('f', { around = 'af', inner = 'if', desc = 'Function' })
--- <
---@param key string
---@param spec {around?: string|fun(range: vim.helix.Range): vim.helix.Range?, inner?: string|fun(range: vim.helix.Range): vim.helix.Range?, desc?: string}
function M.textobject(key, spec)
  vim.validate('key', key, 'string')
  vim.validate('spec', spec, 'table')
  local function adapt(side)
    if type(side) ~= 'function' then
      return side
    end
    return function(s)
      local r = side(to_range(s))
      return r and { a = { r.start[1], r.start[2] }, h = { r.end_[1], r.end_[2] } } or nil
    end
  end
  core().textobjects[vim.keycode(key)] = {
    around = adapt(spec.around),
    inner = adapt(spec.inner),
    desc = spec.desc,
  }
end

local menus = {
  normal = true,
  ['goto'] = true,
  match = true,
  view = true,
  window = true,
  space = true,
  ['['] = true,
  [']'] = true,
}

--- Maps a key in Normal mode or in a Helix minor mode. Minor-mode keys show
--- in its key hints popup.
---
--- Example: >lua
---     vim.helix.map('space', 'f', function()
---       require('telescope.builtin').find_files()
---     end, 'Find files')
---     vim.helix.map('goto', 'x', 'goto_last_line', 'Last line')
--- <
---@param menu 'normal'|'goto'|'match'|'view'|'window'|'space'|'['|']'
---@param lhs string Key (in a minor mode: the key after the prefix).
---@param rhs string|fun() Function, or name of a Helix command (|vim.helix.commands()|).
---@param desc? string
function M.map(menu, lhs, rhs, desc)
  vim.validate('menu', menu, function(m)
    return menus[m] ~= nil
  end, 'a Helix menu name')
  vim.validate('rhs', rhs, { 'string', 'function' })
  local H = core()
  if type(rhs) == 'string' then
    assert(H.commands[rhs], 'unknown Helix command: ' .. rhs)
  end
  if menu == 'normal' then
    local f = rhs
    if type(f) == 'string' then
      local name = f
      f = function()
        H.commands[name].fn()
      end
    end
    vim.keymap.set('n', lhs, H._wrap(f), { desc = desc or (type(rhs) == 'string' and rhs or nil) })
    return
  end
  M.unmap(menu, lhs)
  table.insert(H.menus[menu], { lhs, rhs, desc })
end

--- Removes a key from a Helix minor mode (or a Normal-mode mapping).
---@param menu 'normal'|'goto'|'match'|'view'|'window'|'space'|'['|']'
---@param lhs string
function M.unmap(menu, lhs)
  if menu == 'normal' then
    pcall(vim.keymap.del, 'n', lhs)
    return
  end
  local entries = core().menus[menu]
  local key = vim.keycode(lhs)
  for i = #entries, 1, -1 do
    local keys = entries[i][1]
    keys = type(keys) == 'table' and keys or { keys }
    local rest = vim.tbl_filter(function(k)
      return vim.keycode(k) ~= key
    end, keys)
    if #rest == 0 then
      table.remove(entries, i)
    elseif #rest < #keys then
      entries[i][1] = rest
    end
  end
end

--- Gets the Helix commands (named like in Helix, e.g. "file_picker"), for
--- mappings and |vim.helix.map()|.
---@return table<string, {fn: fun(), desc: string, keys?: string}>
function M.commands()
  return core().commands
end

--- Adds a command: it appears in the command palette (<Space>?) and can be
--- used by name in |vim.helix.map()|.
---@param name string
---@param fn fun()
---@param desc string
function M.add_command(name, fn, desc)
  vim.validate('name', name, 'string')
  vim.validate('fn', fn, 'function')
  core().commands[name] = { fn = core()._wrap(fn), desc = desc or name }
end

---@class vim.helix.PickerItem
---@field text string Display text (fuzzy-matched).
---@field file? string
---@field buf? integer
---@field lnum? integer 1-indexed
---@field col? integer 1-indexed byte column
---@field end_lnum? integer
---@field end_col? integer
---@field action? fun() Run instead of jumping.

---@class vim.helix.PickerOpts
---@field title string
---@field items? vim.helix.PickerItem[]
---@field dynamic? fun(query: string): vim.helix.PickerItem[] Items computed per query (no fuzzy filtering).
---@field on_select? fun(item: vim.helix.PickerItem, how: 'edit'|'split'|'vsplit'|'bg')
---@field preview? boolean

--- Opens a picker (the one used by <Space> mode).
---@param opts vim.helix.PickerOpts
function M.pick(opts)
  require('vim._core.helix_picker').open(opts)
end

--- Replaces the picker UI used by all Helix pickers (files, buffers, symbols,
--- …) with `fn`, e.g. one built on Telescope or fzf-lua. `fn` gets
--- |vim.helix.PickerOpts| (with `on_select` set) and must call
--- `opts.on_select(item, 'edit')` when an item is chosen. Pass nil to
--- restore the builtin picker.
---@param fn? fun(opts: vim.helix.PickerOpts)
function M.set_picker(fn)
  vim.validate('fn', fn, 'function', true)
  require('vim._core.helix_picker').backend = fn
end

return M
