--- @brief
--- Minimal fuzzy picker for Helix mode (Space-mode pickers): a prompt, a
--- result list and an optional preview, all floating windows.
---
--- Keys (Helix): <Tab>/<C-n>/<Down> next, <S-Tab>/<C-p>/<Up> previous,
--- <C-d>/<PageDown> and <C-u>/<PageUp> page, <Home>/<End> first/last, <CR>
--- open, <M-CR> open in background, <C-s>/<C-v> open in split/vsplit, <C-t>
--- toggle preview, <Esc>/<C-c> close.

local api, fn = vim.api, vim.fn

local M = {}

---@class nvim.helix.PickerItem
---@field text string
---@field file? string
---@field buf? integer
---@field lnum? integer 1-indexed
---@field col? integer 1-indexed (byte)
---@field end_lnum? integer
---@field end_col? integer
---@field action? fun()

---@class nvim.helix.PickerOpts
---@field title string
---@field items? nvim.helix.PickerItem[]
---@field dynamic? fun(query: string): nvim.helix.PickerItem[] recomputed per query, not filtered
---@field on_select? fun(item: nvim.helix.PickerItem, how: 'edit'|'split'|'vsplit'|'bg')
---@field preview? boolean

local ns = api.nvim_create_namespace('vim._core.helix_picker')

---@type nvim.helix.PickerOpts?
M.last = nil
local show_preview = true

--- Default open action: jump to the item location.
---@param item nvim.helix.PickerItem
---@param how string
function M.jump(item, how)
  if item.action then
    item.action()
    return
  end
  vim.cmd("normal! m'")
  if how == 'split' then
    vim.cmd.split()
  elseif how == 'vsplit' then
    vim.cmd.vsplit()
  end
  local buf = item.buf
  if not (buf and api.nvim_buf_is_valid(buf)) and item.file then
    local b = fn.bufnr(item.file)
    buf = b > 0 and b or nil
  end
  if buf and api.nvim_buf_is_valid(buf) then
    if buf ~= api.nvim_get_current_buf() then
      api.nvim_set_current_buf(buf)
    end
  elseif item.file then
    vim.cmd.edit(fn.fnameescape(item.file))
  end
  if item.lnum then
    local lc = api.nvim_buf_line_count(0)
    pcall(api.nvim_win_set_cursor, 0, { math.min(item.lnum, lc), math.max(0, (item.col or 1) - 1) })
    vim.cmd('normal! zz')
  end
  local ok, helix = pcall(require, 'vim._core.helix')
  if ok and helix.enabled then
    local sel = require('vim._core.helix_sel')
    if item.end_lnum and item.end_col and item.lnum then
      local a = { item.lnum - 1, (item.col or 1) - 1 }
      local h = sel.prev({ item.end_lnum - 1, item.end_col - 1 }) or a
      if sel.cmp(h, a) < 0 then
        h = a
      end
      sel.set({ { a = a, h = h } })
    else
      sel.reset_to_cursor()
    end
  end
end

--- Replacement picker UI, set by |vim.helix.set_picker()|.
---@type fun(opts: nvim.helix.PickerOpts)?
M.backend = nil

---@param opts nvim.helix.PickerOpts
function M.open(opts)
  M.last = opts
  opts.on_select = opts.on_select or M.jump
  if M.backend then
    M.backend(opts)
    return
  end
  local on_select = opts.on_select or M.jump
  local all = opts.items or {}
  local shown = all ---@type nvim.helix.PickerItem[]
  local idx = 1

  local cols, lines = vim.o.columns, vim.o.lines
  local width = math.min(cols - 4, math.max(60, math.floor(cols * 0.9)))
  local height = math.max(6, math.floor(lines * 0.8) - 2)
  local row = math.floor((lines - height) / 2) - 1
  local col = math.floor((cols - width) / 2)
  local has_preview = opts.preview ~= false and show_preview and width >= 80
  local list_w = has_preview and math.floor(width / 2) or width

  local pbuf = api.nvim_create_buf(false, true)
  local lbuf = api.nvim_create_buf(false, true)
  vim.bo[pbuf].bufhidden = 'wipe'
  vim.bo[lbuf].bufhidden = 'wipe'
  local border = vim.o.winborder ~= '' and vim.o.winborder or 'rounded'
  local lwin = api.nvim_open_win(lbuf, false, {
    relative = 'editor',
    row = row + 3,
    col = col,
    width = list_w,
    height = height - 3,
    style = 'minimal',
    border = border,
    focusable = false,
    zindex = 200,
  })
  vim.wo[lwin].cursorline = true
  vim.wo[lwin].wrap = false
  vim.wo[lwin].winhighlight = 'CursorLine:PmenuSel'
  local pwin = api.nvim_open_win(pbuf, true, {
    relative = 'editor',
    row = row,
    col = col,
    width = list_w,
    height = 1,
    style = 'minimal',
    border = border,
    title = ' ' .. opts.title .. ' ',
    zindex = 201,
  })
  local vbuf, vwin ---@type integer?, integer?

  local function close_preview()
    if vwin and api.nvim_win_is_valid(vwin) then
      api.nvim_win_close(vwin, true)
    end
    vwin = nil
  end

  local function preview()
    if not has_preview then
      close_preview()
      return
    end
    local item = shown[idx]
    if not item or not (item.buf or item.file) then
      close_preview()
      return
    end
    local text ---@type string[]
    if item.buf and api.nvim_buf_is_loaded(item.buf) then
      text = api.nvim_buf_get_lines(item.buf, 0, -1, false)
    elseif
      item.file
      and fn.filereadable(item.file) == 1
      and fn.getfsize(item.file) < 1024 * 1024
    then
      text = fn.readfile(item.file, '', 5000)
    else
      close_preview()
      return
    end
    if not vbuf or not api.nvim_buf_is_valid(vbuf) then
      vbuf = api.nvim_create_buf(false, true)
      vim.bo[vbuf].bufhidden = 'wipe'
    end
    api.nvim_buf_set_lines(vbuf, 0, -1, false, text)
    local name = item.file or api.nvim_buf_get_name(item.buf)
    local ft = vim.filetype.match({ filename = name, buf = vbuf }) or ''
    if vim.bo[vbuf].filetype ~= ft then
      vim.bo[vbuf].filetype = ''
      pcall(function()
        vim.bo[vbuf].syntax = ft
      end)
    end
    if not vwin or not api.nvim_win_is_valid(vwin) then
      vwin = api.nvim_open_win(vbuf, false, {
        relative = 'editor',
        row = row,
        col = col + list_w + 2,
        width = width - list_w - 2,
        height = height,
        style = 'minimal',
        border = border,
        focusable = false,
        zindex = 200,
      })
    end
    local lnum = math.max(1, math.min(item.lnum or 1, #text))
    api.nvim_win_set_cursor(vwin, { lnum, 0 })
    api.nvim_win_call(vwin, function()
      vim.cmd('normal! zz')
    end)
    api.nvim_buf_clear_namespace(vbuf, ns, 0, -1)
    if item.lnum then
      api.nvim_buf_set_extmark(vbuf, ns, lnum - 1, 0, { line_hl_group = 'Visual' })
    end
  end

  local function draw()
    local out = {}
    for i, item in ipairs(shown) do
      out[i] = ' ' .. item.text:gsub('\n', ' ')
    end
    api.nvim_buf_set_lines(lbuf, 0, -1, false, out)
    api.nvim_buf_clear_namespace(pbuf, ns, 0, -1)
    api.nvim_buf_set_extmark(pbuf, ns, 0, 0, {
      virt_text = { { ('%d/%d'):format(#shown, #all), 'Comment' } },
      virt_text_pos = 'right_align',
    })
    idx = math.max(1, math.min(idx, #shown))
    if #shown > 0 then
      api.nvim_win_set_cursor(lwin, { idx, 0 })
    end
    preview()
  end

  local timer ---@type uv.uv_timer_t?
  local last_query = ''
  local function refilter()
    local q = api.nvim_buf_get_lines(pbuf, 0, 1, false)[1] or ''
    last_query = q
    if opts.dynamic then
      if timer then
        timer:stop()
        timer:close()
      end
      timer = vim.defer_fn(function()
        timer = nil
        if not api.nvim_buf_is_valid(pbuf) then
          return
        end
        all = opts.dynamic(q)
        shown = all
        idx = 1
        draw()
      end, 150)
      return
    end
    if q == '' then
      shown = all
    else
      shown = fn.matchfuzzy(all, q, { key = 'text' })
    end
    idx = 1
    draw()
  end

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    vim.cmd.stopinsert()
    close_preview()
    for _, w in ipairs({ pwin, lwin }) do
      if api.nvim_win_is_valid(w) then
        api.nvim_win_close(w, true)
      end
    end
  end

  local function accept(how)
    local q = api.nvim_buf_get_lines(pbuf, 0, 1, false)[1] or ''
    if q ~= last_query and not opts.dynamic then
      -- Typed faster than TextChangedI fired.
      refilter()
    end
    local item = shown[idx]
    if how ~= 'bg' then
      close()
    end
    if item then
      vim.schedule(function()
        on_select(item, how)
      end)
    end
  end

  local function move(d)
    if #shown == 0 then
      return
    end
    idx = ((idx - 1 + d) % #shown) + 1
    draw()
  end

  local page = math.max(1, height - 4)
  local maps = {
    ['<Tab>'] = function()
      move(1)
    end,
    ['<C-n>'] = function()
      move(1)
    end,
    ['<Down>'] = function()
      move(1)
    end,
    ['<S-Tab>'] = function()
      move(-1)
    end,
    ['<C-p>'] = function()
      move(-1)
    end,
    ['<Up>'] = function()
      move(-1)
    end,
    ['<C-d>'] = function()
      idx = math.min(#shown, idx + page)
      draw()
    end,
    ['<PageDown>'] = function()
      idx = math.min(#shown, idx + page)
      draw()
    end,
    ['<C-u>'] = function()
      idx = math.max(1, idx - page)
      draw()
    end,
    ['<PageUp>'] = function()
      idx = math.max(1, idx - page)
      draw()
    end,
    ['<Home>'] = function()
      idx = 1
      draw()
    end,
    ['<End>'] = function()
      idx = #shown
      draw()
    end,
    ['<CR>'] = function()
      accept('edit')
    end,
    ['<M-CR>'] = function()
      accept('bg')
    end,
    ['<C-s>'] = function()
      accept('split')
    end,
    ['<C-v>'] = function()
      accept('vsplit')
    end,
    ['<C-t>'] = function()
      show_preview = not show_preview
      has_preview = show_preview and width >= 80
      draw()
    end,
    ['<Esc>'] = close,
    ['<C-c>'] = close,
  }
  for lhs, rhs in pairs(maps) do
    vim.keymap.set({ 'i', 'n' }, lhs, rhs, { buffer = pbuf, nowait = true })
  end
  api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, { buffer = pbuf, callback = refilter })
  api.nvim_create_autocmd({ 'WinLeave', 'BufLeave' }, {
    buffer = pbuf,
    once = true,
    callback = function()
      vim.schedule(close)
    end,
  })
  draw()
  vim.cmd.startinsert()
end

--- Space-' : reopen the last picker.
function M.resume()
  if M.last then
    M.open(M.last)
  else
    vim.notify('No previous picker', vim.log.levels.WARN)
  end
end

return M
