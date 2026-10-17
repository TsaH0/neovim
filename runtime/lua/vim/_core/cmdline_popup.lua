--- @brief
--- Popup cmdline: draws the |cmdline| (":", "/", "?", |input()| prompts, …)
--- in a floating window with a border and title, instead of the last screen
--- line. Uses the |ui-cmdline| externalization (|ext_cmdline|), so
--- completion, history and mappings work as usual. See 'cmdlinepopup'.

local api, fn = vim.api, vim.fn

local M = {
  ns = api.nvim_create_namespace('nvim.cmdline_popup'),
  hl_ns = api.nvim_create_namespace('nvim.cmdline_popup.hl'),
  enabled = false,
  buf = -1,
  win = -1,
  level = 0,
  block = {}, ---@type string[] Lines of a multi-line (block) cmdline.
}

--- Title and icon per cmdline type (firstc).
local kinds = {
  [':'] = { ' Cmdline ', '> ' },
  ['/'] = { ' Search ', '/ ' },
  ['?'] = { ' Search ', '? ' },
  ['='] = { ' Calculator ', '= ' },
  ['>'] = { ' Debug ', '> ' },
}

local function set_highlights()
  local function link(name, to)
    api.nvim_set_hl(0, name, { link = to, default = true })
  end
  link('CmdlinePopup', 'NormalFloat')
  link('CmdlinePopupBorder', 'DiagnosticInfo')
  link('CmdlinePopupTitle', 'DiagnosticInfo')
  link('CmdlinePopupIcon', 'DiagnosticInfo')
end

--- Window geometry: centered, near the top (like the screenshot in Helix /
--- noice), at most 80 columns.
local function geometry(height)
  local cols = vim.o.columns
  local width = math.max(20, math.min(80, cols - 4, math.floor(cols * 0.6)))
  return {
    relative = 'editor',
    width = width,
    height = math.max(1, height),
    row = math.max(0, math.floor(vim.o.lines * 0.2) - 1),
    col = math.max(0, math.floor((cols - width) / 2) - 1),
  }
end

---@param title string
---@param height integer
---@param offset integer Screen column of the cmdline text (for the completion menu).
local function open_win(title, height, offset)
  if not api.nvim_buf_is_valid(M.buf) then
    M.buf = api.nvim_create_buf(false, true)
    vim.bo[M.buf].bufhidden = 'hide'
    api.nvim_buf_set_name(M.buf, '[Cmdline]')
  end
  local cfg = geometry(height)
  cfg.title = title
  cfg.title_pos = 'center'
  cfg._cmdline_offset = offset
  if api.nvim_win_is_valid(M.win) then
    api.nvim_win_set_config(M.win, vim.tbl_extend('force', cfg, { hide = false }))
    return
  end
  cfg.style = 'minimal'
  cfg.border = vim.o.winborder ~= '' and vim.o.winborder or 'rounded'
  cfg.focusable = false
  cfg.noautocmd = true
  cfg.zindex = 240 -- Below the cmdline completion popupmenu (250).
  M.win = api.nvim_open_win(M.buf, false, cfg)
  vim.wo[M.win].winhighlight = table.concat({
    'Normal:CmdlinePopup',
    'FloatBorder:CmdlinePopupBorder',
    'FloatTitle:CmdlinePopupTitle',
    'Search:,CurSearch:,IncSearch:',
  }, ',')
  vim.wo[M.win].wrap = true
  vim.wo[M.win].winpinned = true
end

local function hide()
  if api.nvim_win_is_valid(M.win) then
    api.nvim_win_set_config(M.win, { hide = true })
  end
end

local text = '' ---@type string Current cmdline text.
local prefix = '' ---@type string Icon/prompt before the text.

--- Highlights a ":" command line as Vimscript.
local function highlight_vim(row, col)
  local line = text
  local ok, parser = pcall(vim.treesitter.get_string_parser, line, 'vim')
  if not ok or not parser then
    return
  end
  parser:parse(true)
  parser:for_each_tree(function(tstree, tree)
    local query = tstree and vim.treesitter.query.get(tree:lang(), 'highlights')
    if not query then
      return
    end
    for id, node in query:iter_captures(tstree:root(), line) do
      local _, sc, _, ec = node:range()
      local name = query.captures[id]
      if name and name:sub(1, 1) ~= '_' then
        pcall(api.nvim_buf_set_extmark, M.buf, M.hl_ns, row, col + sc, {
          end_col = col + ec,
          hl_group = ('@%s.%s'):format(name, query.lang),
        })
      end
    end
  end)
end

---@param pos integer Byte position of the cursor in the cmdline text.
local function set_cursor(pos)
  if not api.nvim_win_is_valid(M.win) then
    return
  end
  local row = #M.block
  local col = #prefix + #fn.strtrans(text:sub(1, pos))
  pcall(api.nvim_win_set_cursor, M.win, { row + 1, col })
  api.nvim__redraw({ cursor = true, win = M.win, flush = true })
end

---@param content [integer, string][]
---@param pos integer
---@param firstc string
---@param prompt string
---@param indent integer
---@param level integer
---@param hl_id integer
local function cmdline_show(content, pos, firstc, prompt, indent, level, hl_id)
  M.level = level
  text = ''
  for _, chunk in ipairs(content) do
    text = text .. chunk[2]
  end
  local kind = kinds[firstc]
  local title, icon
  if kind and prompt == '' then
    title, icon = kind[1], kind[2]
  elseif kinds[prompt] then
    -- input() used as a search prompt (e.g. Helix "/").
    title, icon = kinds[prompt][1], kinds[prompt][2]
  else
    -- input() prompts: "select: " is titled "Select".
    local name = vim.trim(prompt):match('^([%w][%w _-]*):$')
    if name and #name <= 30 then
      title, icon = ' ' .. name:sub(1, 1):upper() .. name:sub(2) .. ' ', '> '
    else
      title = ' Input '
      icon = (firstc ~= '' and firstc or '') .. fn.strtrans(prompt):gsub('\n', ' ')
    end
  end
  prefix = icon .. (' '):rep(indent)

  local lines = vim.list_extend({}, M.block)
  lines[#lines + 1] = prefix .. fn.strtrans(text)
  local width = geometry(1).width
  local height = 0
  for _, l in ipairs(lines) do
    height = height + math.max(1, math.ceil((fn.strdisplaywidth(l) + 1) / width))
  end
  open_win(title, math.min(height, math.floor(vim.o.lines / 2)), fn.strdisplaywidth(prefix))
  api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  api.nvim_buf_clear_namespace(M.buf, M.hl_ns, 0, -1)
  local row = #lines - 1
  if #icon > 0 then
    api.nvim_buf_set_extmark(M.buf, M.hl_ns, row, 0, {
      end_col = #icon,
      hl_group = (hl_id and hl_id > 0) and hl_id or 'CmdlinePopupIcon',
    })
  end
  if firstc == ':' then
    highlight_vim(row, #prefix)
  end
  set_cursor(pos)
end

local handlers = {} ---@type table<string, function>

handlers.cmdline_show = cmdline_show

function handlers.cmdline_pos(pos, _level)
  set_cursor(pos)
end

function handlers.cmdline_special_char(c, shift, _level)
  if not api.nvim_win_is_valid(M.win) then
    return
  end
  api.nvim_win_call(M.win, function()
    api.nvim_put({ c }, shift and '' or 'c', false, false)
  end)
  api.nvim__redraw({ cursor = true, win = M.win, flush = true })
end

function handlers.cmdline_hide(level, _abort)
  if level > 1 then
    return
  end
  M.level = 0
  M.block = {}
  hide()
  api.nvim__redraw({ flush = true })
end

function handlers.cmdline_block_show(lines)
  M.block = {}
  for _, content in ipairs(lines) do
    local l = ''
    for _, chunk in ipairs(content) do
      l = l .. chunk[2]
    end
    M.block[#M.block + 1] = ': ' .. l
  end
end

function handlers.cmdline_block_append(line)
  local l = ''
  for _, chunk in ipairs(line) do
    l = l .. chunk[2]
  end
  M.block[#M.block + 1] = ': ' .. l
end

function handlers.cmdline_block_hide()
  M.block = {}
  hide()
end

--- Whether ui2 (which draws its own cmdline) is active.
local function ui2_active()
  local ui2 = package.loaded['vim._core.ui2']
  return ui2 ~= nil and ui2.cfg.enable ~= false and ui2.msg ~= nil
end

--- Enables the popup cmdline.
function M.enable()
  if M.enabled then
    return
  end
  M.enabled = true
  set_highlights()
  local group = api.nvim_create_augroup('nvim.cmdline_popup', {})
  api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_highlights })
  api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      if api.nvim_win_is_valid(M.win) then
        api.nvim_win_set_config(M.win, geometry(api.nvim_win_get_height(M.win)))
      end
    end,
  })
  vim.ui_attach(M.ns, { ext_cmdline = true }, function(event, ...)
    local h = handlers[event]
    if not h or ui2_active() then
      return
    end
    local args = { ... }
    if vim.in_fast_event() then
      vim.schedule(function()
        h(unpack(args))
      end)
    else
      local ok, err = pcall(h, ...)
      if not ok then
        -- Never break the cmdline: fall back to the builtin one.
        M.disable()
        vim.schedule(function()
          vim.notify('cmdline popup disabled: ' .. tostring(err), vim.log.levels.ERROR)
        end)
      end
    end
    return true
  end)
end

--- Called when 'cmdlinepopup' is set: enables the popup when a UI is attached.
---@param on boolean
function M.sync(on)
  if on and #api.nvim_list_uis() > 0 then
    M.enable()
  elseif not on then
    M.disable()
  end
end

--- Disables the popup cmdline (back to the builtin cmdline).
function M.disable()
  if not M.enabled then
    return
  end
  M.enabled = false
  vim.ui_detach(M.ns)
  pcall(api.nvim_del_augroup_by_name, 'nvim.cmdline_popup')
  if api.nvim_win_is_valid(M.win) then
    api.nvim_win_close(M.win, true)
  end
end

return M
