--- @brief
--- Helix-style selection model: every buffer has one or more selections,
--- each an (anchor, head) pair of character positions. The primary
--- selection's head is the real cursor.
---
--- Positions are `{row, col}`, 0-indexed, `col` a byte index. `col == #line`
--- addresses the line's newline character (like Helix, selections can include
--- line endings), so 'virtualedit' must contain "onemore".

local api = vim.api

local M = {}

M.ns = api.nvim_create_namespace('nvim.helix.selection')
M.track_ns = api.nvim_create_namespace('nvim.helix.track')
M.mc_ns = api.nvim_create_namespace('nvim.multicursor')

---@alias nvim.helix.Pos [integer, integer]

---@class nvim.helix.Sel
---@field a nvim.helix.Pos anchor
---@field h nvim.helix.Pos head
---@field want? integer desired display column for vertical motions

---@class nvim.helix.State
---@field sels nvim.helix.Sel[]
---@field primary integer
---@field history? nvim.helix.Sel[][] TS expand history (for shrink)

--- Per-buffer state.
---@type table<integer, nvim.helix.State>
M.states = {}

--- 'normal' | 'select'
M.mode = 'normal'

--- Set while we move the cursor ourselves, so CursorMoved doesn't collapse.
M.busy = false

-- Text helpers {{{

---@param r integer
---@param buf? integer
---@return string
function M.line(r, buf)
  return api.nvim_buf_get_lines(buf or 0, r, r + 1, false)[1] or ''
end

function M.line_count(buf)
  return api.nvim_buf_line_count(buf or 0)
end

--- Byte length of the UTF-8 char starting at byte `c` (0-indexed) of `l`.
---@param l string
---@param c integer
function M.charlen(l, c)
  local b = l:byte(c + 1)
  if not b then
    return 1
  elseif b < 0x80 then
    return 1
  elseif b < 0xE0 then
    return 2
  elseif b < 0xF0 then
    return 3
  end
  return 4
end

--- Snaps `c` to the start of the char containing it.
local function char_start(l, c)
  while c > 0 and c < #l do
    local b = l:byte(c + 1)
    if b < 0x80 or b >= 0xC0 then
      break
    end
    c = c - 1
  end
  return c
end

---@param p nvim.helix.Pos
---@return nvim.helix.Pos?
function M.next(p)
  local l = M.line(p[1])
  if p[2] < #l then
    return { p[1], p[2] + M.charlen(l, p[2]) }
  elseif p[1] < M.line_count() - 1 then
    return { p[1] + 1, 0 }
  end
end

---@param p nvim.helix.Pos
---@return nvim.helix.Pos?
function M.prev(p)
  if p[2] > 0 then
    local l = M.line(p[1])
    return { p[1], char_start(l, math.min(p[2], #l) - 1) }
  elseif p[1] > 0 then
    return { p[1] - 1, #M.line(p[1] - 1) }
  end
end

--- Character at `p` ("\n" at end of line).
---@param p nvim.helix.Pos
function M.char(p)
  local l = M.line(p[1])
  if p[2] >= #l then
    return '\n'
  end
  return l:sub(p[2] + 1, p[2] + M.charlen(l, p[2]))
end

---@param ch string
---@param long? boolean WORD instead of word
---@return 'eol'|'ws'|'word'|'punct'
function M.class(ch, long)
  if ch == '\n' then
    return 'eol'
  elseif ch:match('^%s$') then
    return 'ws'
  elseif long or #ch > 1 or ch:match('^[%w_]$') then
    return 'word'
  end
  return 'punct'
end

---@param p nvim.helix.Pos
---@param q nvim.helix.Pos
---@return integer -1, 0, 1
function M.cmp(p, q)
  if p[1] ~= q[1] then
    return p[1] < q[1] and -1 or 1
  elseif p[2] ~= q[2] then
    return p[2] < q[2] and -1 or 1
  end
  return 0
end

function M.from(s)
  return M.cmp(s.a, s.h) <= 0 and s.a or s.h
end

function M.to(s)
  return M.cmp(s.a, s.h) <= 0 and s.h or s.a
end

--- Clamps `p` to a valid position in the current buffer.
---@param p nvim.helix.Pos
---@return nvim.helix.Pos
function M.clamp(p)
  local lc = M.line_count()
  local r = math.max(0, math.min(p[1], lc - 1))
  local l = M.line(r)
  local c = math.max(0, math.min(p[2], #l))
  return { r, char_start(l, c) }
end

--- Exclusive end position after the char at `p` (for API text ranges).
---@param p nvim.helix.Pos
---@return nvim.helix.Pos
function M.after(p)
  local l = M.line(p[1])
  if p[2] < #l then
    return { p[1], p[2] + M.charlen(l, p[2]) }
  elseif p[1] < M.line_count() - 1 then
    return { p[1] + 1, 0 }
  end
  return { p[1], #l }
end

--- Text covered by selection `s` (inclusive of both ends).
---@param s nvim.helix.Sel
---@return string
function M.text(s)
  local f, e = M.from(s), M.after(M.to(s))
  local lines = api.nvim_buf_get_text(0, f[1], f[2], e[1], e[2], {})
  local text = table.concat(lines, '\n')
  -- The final line has an implicit newline in Helix.
  if M.to(s)[1] == M.line_count() - 1 and M.to(s)[2] >= #M.line(M.to(s)[1]) then
    text = text .. '\n'
  end
  return text
end

--- Inserts `text` at `p`. Returns the inclusive end of the inserted text.
---@param p nvim.helix.Pos
---@param text string
---@return nvim.helix.Pos
function M.insert(p, text)
  local lines = vim.split(text, '\n', { plain = true })
  api.nvim_buf_set_text(0, p[1], p[2], p[1], p[2], lines)
  local e ---@type nvim.helix.Pos
  if #lines == 1 then
    e = { p[1], p[2] + #text }
  else
    e = { p[1] + #lines - 1, #lines[#lines] }
  end
  return M.prev(e) or p
end

--- Deletes the text of selection `s`. Returns the position where it was.
---@param s nvim.helix.Sel
---@return nvim.helix.Pos
function M.delete(s)
  local f, t = M.from(s), M.to(s)
  local e = M.after(t)
  local lc = M.line_count()
  if t[1] == lc - 1 and t[2] >= #M.line(t[1]) and f[2] == 0 and f[1] > 0 then
    -- Deleting whole trailing lines: also remove the preceding newline.
    local pl = M.line(f[1] - 1)
    api.nvim_buf_set_text(0, f[1] - 1, #pl, t[1], #M.line(t[1]), { '' })
    return { f[1] - 1, 0 }
  end
  api.nvim_buf_set_text(0, f[1], f[2], e[1], e[2], { '' })
  return M.clamp(f)
end

--- Replaces the text of `s` with `text`. Returns the new selection.
---@param s nvim.helix.Sel
---@param text string
---@return nvim.helix.Sel
function M.replace(s, text)
  local f, t = M.from(s), M.to(s)
  local e = M.after(t)
  local old = M.text(s)
  -- Keep the trailing newline if the old text didn't really have one.
  if t[1] == M.line_count() - 1 and t[2] >= #M.line(t[1]) and old:sub(-1) == '\n' then
    e = { t[1], #M.line(t[1]) }
    if text:sub(-1) == '\n' then
      text = text:sub(1, -2)
    end
  end
  local lines = vim.split(text, '\n', { plain = true })
  api.nvim_buf_set_text(0, f[1], f[2], e[1], e[2], lines)
  if text == '' then
    local p = M.clamp(f)
    return { a = p, h = p }
  end
  local last ---@type nvim.helix.Pos
  if #lines == 1 then
    last = { f[1], f[2] + #text }
  else
    last = { f[1] + #lines - 1, #lines[#lines] }
  end
  local h = M.prev(last) or f
  if M.cmp(s.a, s.h) > 0 then
    return { a = h, h = f }
  end
  return { a = f, h = h }
end

-- }}}

-- State {{{

---@param buf? integer
---@return nvim.helix.State
function M.get(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local st = M.states[buf]
  if not st then
    local c = api.nvim_win_get_cursor(0)
    local p = { c[1] - 1, c[2] }
    st = { sels = { { a = p, h = p } }, primary = 1 }
    M.states[buf] = st
  end
  return st
end

function M.primary()
  local st = M.get()
  return st.sels[st.primary]
end

--- Sorts and merges overlapping selections, preserving the primary.
---@param sels nvim.helix.Sel[]
---@param primary integer
---@return nvim.helix.Sel[], integer
function M.normalize(sels, primary)
  for i, s in ipairs(sels) do
    s.i = i
    s.a = M.clamp(s.a)
    s.h = M.clamp(s.h)
  end
  table.sort(sels, function(x, y)
    local c = M.cmp(M.from(x), M.from(y))
    if c ~= 0 then
      return c < 0
    end
    return M.cmp(M.to(x), M.to(y)) < 0
  end)
  local out = {} ---@type nvim.helix.Sel[]
  local newp = 1
  for _, s in ipairs(sels) do
    local last = out[#out]
    if last and M.cmp(M.from(s), M.to(last)) <= 0 then
      -- Overlap: merge into `last`.
      local f = M.from(last)
      local t = M.cmp(M.to(s), M.to(last)) > 0 and M.to(s) or M.to(last)
      local backward = M.cmp(last.h, last.a) < 0
      last.a, last.h = backward and t or f, backward and f or t
      if s.i == primary then
        newp = #out
      end
    else
      out[#out + 1] = s
      if s.i == primary then
        newp = #out
      end
    end
  end
  for _, s in ipairs(out) do
    s.i = nil
  end
  return out, newp
end

--- Replaces the selections of the current buffer and redraws them.
---@param sels nvim.helix.Sel[]
---@param primary? integer
function M.set(sels, primary)
  local st = M.get()
  if #sels == 0 then
    return
  end
  primary = math.max(1, math.min(primary or #sels, #sels))
  st.sels, st.primary = M.normalize(sels, primary)
  M.sync_cursor()
  M.render()
  M.changed()
end

--- Fires |HelixSelectionChanged| (once per event-loop tick).
local change_pending = false
function M.changed()
  if change_pending then
    return
  end
  change_pending = true
  vim.schedule(function()
    change_pending = false
    api.nvim_exec_autocmds('User', { pattern = 'HelixSelectionChanged', modeline = false })
  end)
end

--- Moves the real cursor to the primary head.
function M.sync_cursor()
  local s = M.primary()
  M.busy = true
  pcall(api.nvim_win_set_cursor, 0, { s.h[1] + 1, s.h[2] })
  M.busy = false
  -- Keep '< and '> on the primary selection, for ":'<,'>" and friends.
  local f, t = M.from(s), M.to(s)
  pcall(api.nvim_buf_set_mark, 0, '<', f[1] + 1, f[2], {})
  pcall(api.nvim_buf_set_mark, 0, '>', t[1] + 1, t[2], {})
end

--- Collapses to a single cursor at the real cursor position.
function M.reset_to_cursor()
  local c = api.nvim_win_get_cursor(0)
  local p = M.clamp({ c[1] - 1, c[2] })
  local st = M.get()
  st.sels, st.primary = { { a = p, h = vim.deepcopy(p) } }, 1
  M.render()
  M.changed()
end

--- Draws selections as extmarks.
---@param buf? integer
function M.render(buf)
  buf = buf or api.nvim_get_current_buf()
  api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  local st = M.states[buf]
  if not st or buf ~= api.nvim_get_current_buf() then
    return
  end
  local lc = M.line_count()
  for i, s in ipairs(st.sels) do
    local f, t = M.from(s), M.to(s)
    local hl = i == st.primary and 'HelixSelectionPrimary' or 'HelixSelection'
    if M.cmp(f, t) ~= 0 then
      local e = M.after(t)
      local eol = t[2] >= #M.line(t[1])
      if eol and t[1] == lc - 1 then
        e = { t[1], #M.line(t[1]) }
      end
      pcall(api.nvim_buf_set_extmark, buf, M.ns, f[1], f[2], {
        end_row = e[1],
        end_col = e[2],
        hl_group = hl,
        hl_eol = eol,
        priority = 150,
        strict = false,
      })
    end
    if i ~= st.primary then
      local h = s.h
      if h[2] >= #M.line(h[1]) then
        pcall(api.nvim_buf_set_extmark, buf, M.ns, h[1], h[2], {
          virt_text = { { ' ', 'HelixCursor' } },
          virt_text_pos = 'overlay',
          priority = 160,
          strict = false,
        })
      else
        local e = M.after(h)
        pcall(api.nvim_buf_set_extmark, buf, M.ns, h[1], h[2], {
          end_row = e[1],
          end_col = e[2],
          hl_group = 'HelixCursor',
          priority = 160,
          strict = false,
        })
      end
    end
  end
end

-- }}}

-- Tracking positions across edits {{{

--- Creates a tracking extmark at `p`.
---@param p nvim.helix.Pos
---@param right_gravity? boolean default true
---@return integer
function M.mark(p, right_gravity)
  p = M.clamp(p)
  return api.nvim_buf_set_extmark(0, M.track_ns, p[1], p[2], {
    right_gravity = right_gravity ~= false,
  })
end

---@param id integer
---@return nvim.helix.Pos
function M.unmark(id)
  local m = api.nvim_buf_get_extmark_by_id(0, M.track_ns, id, {})
  api.nvim_buf_del_extmark(0, M.track_ns, id)
  return M.clamp({ m[1] or 0, m[2] or 0 })
end

--- Runs `f(sel, i)` for each selection, last (in buffer order) first, so
--- edits don't invalidate positions not yet visited. `f` returns the new
--- selection(s) for that selection (or nil to drop it); positions are
--- tracked through later edits. Updates the selections.
---@param f fun(s: nvim.helix.Sel, i: integer): (nvim.helix.Sel|nvim.helix.Sel[]|nil)
---@param opts? {keep_primary?: boolean}
function M.transform(f, opts)
  local st = M.get()
  local sels = st.sels
  local results = {} ---@type table<integer, {[1]:integer,[2]:integer}[]>
  for i = #sels, 1, -1 do
    local out = f(vim.deepcopy(sels[i]), i)
    if out then
      if out.a then
        out = { out }
      end
      results[i] = {}
      for _, s in ipairs(out) do
        table.insert(results[i], { M.mark(s.a), M.mark(s.h) })
      end
    end
  end
  local new, primary = {}, 1 ---@type nvim.helix.Sel[], integer
  for i = 1, #sels do
    for j, ids in ipairs(results[i] or {}) do
      new[#new + 1] = { a = M.unmark(ids[1]), h = M.unmark(ids[2]) }
      if i == st.primary and (j == 1 or not (opts and opts.keep_primary)) then
        primary = #new
      end
    end
  end
  if #new == 0 then
    M.reset_to_cursor()
    return
  end
  M.set(new, primary)
end

--- Runs `f()` (which may edit the buffer arbitrarily) while tracking the
--- selections through the edits.
---@param f fun()
function M.track(f)
  local st = M.get()
  local ids = {}
  for i, s in ipairs(st.sels) do
    ids[i] = { M.mark(s.a), M.mark(s.h) }
  end
  local ok, err = pcall(f)
  local new = {}
  for i, id in ipairs(ids) do
    new[i] = { a = M.unmark(id[1]), h = M.unmark(id[2]) }
  end
  M.set(new, st.primary)
  if not ok then
    error(err, 0)
  end
end

-- }}}

return M
