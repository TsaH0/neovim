--- @brief
--- File explorer with yazi-style keys (|file-explorer|): three columns
--- (parent directory, current directory, preview) in floating windows.
--- Opened by <Space>e / <Space>. in |helix-mode|, or |:Explorer|.

local api, fn, uv = vim.api, vim.fn, vim.uv

local M = {}

local ns = api.nvim_create_namespace('nvim.explorer')

---@class (private) nvim.explorer.Entry
---@field name string
---@field dir boolean
---@field link boolean

---@class (private) nvim.explorer.State
---@field cwd string
---@field entries nvim.explorer.Entry[]
---@field hidden boolean show dotfiles
---@field marks table<string, true> selected paths
---@field clip? {paths: string[], cut: boolean}
---@field pos table<string, string> last hovered name per directory
---@field origin_win integer window to open files in
---@field wins {parent: integer, cur: integer, prev: integer}
---@field bufs {parent: integer, cur: integer, prev: integer}
---@field search? string
---@field filter? string

---@type nvim.explorer.State?
local S = nil
--- Persisted between sessions of the explorer.
---@type {hidden: boolean, clip?: {paths: string[], cut: boolean}}
local persist = { hidden = false, clip = nil }

local function join(dir, name)
  return vim.fs.joinpath(dir, name)
end

local function notify(msg, level)
  vim.notify('explorer: ' .. msg, level or vim.log.levels.INFO)
end

---@param dir string
---@param hidden boolean
---@param filter? string
---@return nvim.explorer.Entry[]
local function list(dir, hidden, filter)
  local out = {}
  local handle = uv.fs_scandir(dir)
  if not handle then
    return out
  end
  while true do
    local name, type = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if
      (hidden or name:sub(1, 1) ~= '.')
      and (not filter or name:lower():find(filter:lower(), 1, true))
    then
      local isdir = type == 'directory'
      local link = type == 'link'
      if link then
        local st = uv.fs_stat(join(dir, name))
        isdir = st ~= nil and st.type == 'directory'
      end
      out[#out + 1] = { name = name, dir = isdir, link = link }
    end
  end
  table.sort(out, function(a, b)
    if a.dir ~= b.dir then
      return a.dir
    end
    return a.name:lower() < b.name:lower()
  end)
  return out
end

local function hovered()
  if not S or not api.nvim_win_is_valid(S.wins.cur) then
    return nil
  end
  local row = api.nvim_win_get_cursor(S.wins.cur)[1]
  return S.entries[row]
end

--- Paths to act on: the selected ones, else the hovered one.
---@return string[]
local function targets()
  assert(S)
  local out = vim.tbl_keys(S.marks)
  if #out == 0 then
    local e = hovered()
    if e then
      out = { join(S.cwd, e.name) }
    end
  end
  table.sort(out)
  return out
end

---@param buf integer
---@param entries nvim.explorer.Entry[]
---@param dir string
local function fill(buf, entries, dir)
  local lines = {}
  for i, e in ipairs(entries) do
    lines[i] = ' ' .. e.name:gsub('\n', '\\n') .. (e.dir and '/' or '')
  end
  if #lines == 0 then
    lines = { '' }
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if #entries == 0 then
    api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      virt_text = { { ' (empty)', 'Comment' } },
      virt_text_pos = 'overlay',
    })
  end
  for i, e in ipairs(entries) do
    local path = join(dir, e.name)
    local hl = e.dir and 'Directory' or (e.link and 'Constant' or nil)
    if S and S.clip and S.clip.cut and vim.tbl_contains(S.clip.paths, path) then
      hl = 'Comment'
    end
    if hl then
      api.nvim_buf_set_extmark(buf, ns, i - 1, 1, { end_col = #lines[i], hl_group = hl })
    end
    if S and S.marks[path] then
      api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        virt_text = { { '▍', 'DiagnosticWarn' } },
        virt_text_pos = 'overlay',
        line_hl_group = 'Visual',
      })
    elseif S and S.clip and vim.tbl_contains(S.clip.paths, path) then
      api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        virt_text = { { '▍', S.clip.cut and 'DiagnosticError' or 'DiagnosticOk' } },
        virt_text_pos = 'overlay',
      })
    end
  end
end

local function preview()
  if not S then
    return
  end
  local buf = S.bufs.prev
  local e = hovered()
  vim.bo[buf].modifiable = true
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  pcall(vim.treesitter.stop, buf)
  vim.bo[buf].syntax = ''
  if not e then
    api.nvim_buf_set_lines(buf, 0, -1, false, {})
  elseif e.dir then
    local entries = list(join(S.cwd, e.name), S.hidden)
    vim.bo[buf].modifiable = false
    fill(buf, entries, join(S.cwd, e.name))
    return
  else
    local path = join(S.cwd, e.name)
    local st = uv.fs_stat(path)
    local lines ---@type string[]
    if not st then
      lines = { '(unreadable)' }
    elseif st.size > 10 * 1024 * 1024 then
      lines = { ('(%d bytes)'):format(st.size) }
    else
      local f = io.open(path, 'rb')
      local data = f and f:read(64 * 1024) or ''
      if f then
        f:close()
      end
      if data:find('\0', 1, true) then
        lines = { ('(binary file, %d bytes)'):format(st.size) }
      else
        lines = vim.split(data, '\r?\n')
        if #lines > 300 then
          lines = vim.list_slice(lines, 1, 300)
        end
        api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        local ft = vim.filetype.match({ filename = path, contents = lines })
        if ft then
          local lang = vim.treesitter.language.get_lang(ft)
          if not (lang and pcall(vim.treesitter.start, buf, lang)) then
            vim.bo[buf].syntax = ft
          end
        end
        vim.bo[buf].modifiable = false
        return
      end
    end
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  vim.bo[buf].modifiable = false
end

local function title(s, max)
  s = fn.fnamemodify(s, ':~')
  if #s > max then
    s = '…' .. s:sub(-max + 1)
  end
  return ' ' .. s .. ' '
end

--- Re-reads and redraws everything. Keeps the hovered entry (or `select`).
---@param select? string name to hover
local function refresh(select)
  if not S then
    return
  end
  local keep = select or (hovered() or {}).name or S.pos[S.cwd]
  S.entries = list(S.cwd, S.hidden, S.filter)
  fill(S.bufs.cur, S.entries, S.cwd)
  local row = 1
  for i, e in ipairs(S.entries) do
    if e.name == keep then
      row = i
    end
  end
  api.nvim_win_set_cursor(S.wins.cur, { math.min(row, math.max(1, #S.entries)), 0 })
  -- Parent column, hovering the current directory.
  local parent = vim.fs.dirname(S.cwd)
  if parent ~= S.cwd then
    local pe = list(parent, S.hidden)
    fill(S.bufs.parent, pe, parent)
    local base = vim.fs.basename(S.cwd)
    for i, e in ipairs(pe) do
      if e.name == base then
        api.nvim_win_set_cursor(S.wins.parent, { i, 0 })
      end
    end
  else
    fill(S.bufs.parent, {}, parent)
  end
  local w = api.nvim_win_get_width(S.wins.cur)
  local t = title(S.cwd, w - 4)
  if S.filter then
    t = t .. ('[filter: %s] '):format(S.filter)
  end
  api.nvim_win_set_config(S.wins.cur, { title = t, title_pos = 'center' })
  preview()
end

---@param dir string
---@param select? string
local function cd(dir, select)
  assert(S)
  local h = hovered()
  if h then
    S.pos[S.cwd] = h.name
  end
  S.cwd = vim.fs.normalize(dir)
  S.filter = nil
  S.marks = {}
  refresh(select or S.pos[S.cwd])
end

function M.close()
  if not S then
    return
  end
  local state = S
  S = nil
  persist.hidden, persist.clip = state.hidden, state.clip
  for _, w in pairs(state.wins) do
    if api.nvim_win_is_valid(w) then
      api.nvim_win_close(w, true)
    end
  end
  if api.nvim_win_is_valid(state.origin_win) then
    api.nvim_set_current_win(state.origin_win)
  end
end

---@param how? 'edit'|'split'|'vsplit'|'tab'
local function open_file(path, how)
  M.close()
  local cmds = { edit = 'edit', split = 'split', vsplit = 'vsplit', tab = 'tabedit' }
  local cmd = cmds[how or 'edit']
  vim.cmd[cmd](fn.fnameescape(path))
end

local function enter(how)
  assert(S)
  local e = hovered()
  if not e then
    return
  end
  local path = join(S.cwd, e.name)
  if e.dir then
    cd(path)
  else
    open_file(path, how)
  end
end

local function leave()
  assert(S)
  local parent = vim.fs.dirname(S.cwd)
  if parent ~= S.cwd then
    cd(parent, vim.fs.basename(S.cwd))
  end
end

---@param prompt string
---@param default? string
---@return string?
local function input(prompt, default)
  local ok, s = pcall(fn.input, { prompt = prompt, default = default or '', cancelreturn = '\0' })
  if not ok or s == '\0' then
    return nil
  end
  return s
end

local function exists(path)
  return uv.fs_lstat(path) ~= nil
end

--- A free name for `name` in `dir` ("a.txt" → "a_1.txt").
local function free_name(dir, name)
  if not exists(join(dir, name)) then
    return name
  end
  local base, ext = name:match('^(.+)(%.[^.]+)$')
  base, ext = base or name, ext or ''
  for i = 1, 1000 do
    local n = ('%s_%d%s'):format(base, i, ext)
    if not exists(join(dir, n)) then
      return n
    end
  end
  return name
end

---@return boolean ok
local function copy(src, dst)
  local st = uv.fs_lstat(src)
  if not st then
    return false
  end
  if st.type == 'directory' then
    if not uv.fs_mkdir(dst, st.mode) then
      return false
    end
    for name in vim.fs.dir(src) do
      if not copy(join(src, name), join(dst, name)) then
        return false
      end
    end
    return true
  elseif st.type == 'link' then
    local target = uv.fs_readlink(src)
    return target ~= nil and uv.fs_symlink(target, dst) ~= nil
  end
  return uv.fs_copyfile(src, dst) ~= nil
end

--- Renames buffers of files that were moved.
local function rename_buffers(from, to)
  for _, b in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_get_name(b)
    if name == from or vim.startswith(name, from .. '/') then
      pcall(api.nvim_buf_set_name, b, to .. name:sub(#from + 1))
    end
  end
end

local actions = {}

function actions.create()
  local name = input('Create (end with / for a directory): ')
  if not name or name == '' then
    return
  end
  assert(S)
  local path = join(S.cwd, name)
  if exists(path) then
    notify(name .. ' already exists', vim.log.levels.WARN)
    return
  end
  if name:sub(-1) == '/' then
    fn.mkdir(path, 'p')
  else
    fn.mkdir(vim.fs.dirname(path), 'p')
    local f = io.open(path, 'w')
    if f then
      f:close()
    end
  end
  refresh(vim.split(name, '/')[1])
end

function actions.rename()
  local e = hovered()
  if not e then
    return
  end
  assert(S)
  local name = input('Rename: ', e.name)
  if not name or name == '' or name == e.name then
    return
  end
  local from, to = join(S.cwd, e.name), join(S.cwd, name)
  if exists(to) then
    notify(name .. ' already exists', vim.log.levels.WARN)
    return
  end
  local ok, err = uv.fs_rename(from, to)
  if not ok then
    notify(tostring(err), vim.log.levels.ERROR)
    return
  end
  rename_buffers(from, to)
  refresh(name)
end

---@param permanent boolean
local function remove(permanent)
  assert(S)
  local paths = targets()
  if #paths == 0 then
    return
  end
  local what = #paths == 1 and fn.fnamemodify(paths[1], ':t') or (#paths .. ' items')
  local trash ---@type string[]?
  if not permanent then
    if fn.executable('trash') == 1 then
      trash = { 'trash' }
    elseif fn.executable('trash-put') == 1 then
      trash = { 'trash-put' }
    elseif fn.executable('gio') == 1 then
      trash = { 'gio', 'trash' }
    elseif fn.executable('kioclient') == 1 then
      trash = { 'kioclient', 'move' }
    end
  end
  local verb = trash and 'Trash' or 'Permanently delete'
  local answer = input(('%s %s? (y/N) '):format(verb, what))
  if not answer or not answer:lower():match('^y') then
    return
  end
  for _, p in ipairs(paths) do
    if trash then
      local cmd = vim.list_extend(vim.deepcopy(trash), { p })
      if trash[1] == 'kioclient' then
        cmd[#cmd + 1] = 'trash:/'
      end
      local r = vim.system(cmd):wait()
      if r.code ~= 0 then
        local msg = ('%s failed: %s'):format(table.concat(trash, ' '), r.stderr or '')
        notify(msg, vim.log.levels.ERROR)
      end
    else
      local ok, err = pcall(vim.fs.rm, p, { recursive = true, force = true })
      if not ok then
        notify(tostring(err), vim.log.levels.ERROR)
      end
    end
  end
  S.marks = {}
  refresh()
end

function actions.trash()
  remove(false)
end

function actions.delete()
  remove(true)
end

---@param cut boolean
local function yank(cut)
  assert(S)
  local paths = targets()
  if #paths == 0 then
    return
  end
  S.clip = { paths = paths, cut = cut }
  S.marks = {}
  notify(('%s %d item%s'):format(cut and 'cut' or 'yanked', #paths, #paths == 1 and '' or 's'))
  refresh()
end

function actions.yank()
  yank(false)
end

function actions.cut()
  yank(true)
end

function actions.unyank()
  assert(S)
  S.clip = nil
  refresh()
end

---@param force boolean overwrite existing files
local function paste(force)
  assert(S)
  if not S.clip then
    notify('nothing yanked', vim.log.levels.WARN)
    return
  end
  local last
  for _, src in ipairs(S.clip.paths) do
    local name = vim.fs.basename(src)
    if not force then
      name = free_name(S.cwd, name)
    elseif exists(join(S.cwd, name)) and join(S.cwd, name) ~= src then
      pcall(vim.fs.rm, join(S.cwd, name), { recursive = true, force = true })
    end
    local dst = join(S.cwd, name)
    if src ~= dst then
      local ok
      if S.clip.cut then
        ok = uv.fs_rename(src, dst)
        if not ok then -- Across filesystems.
          ok = copy(src, dst) and pcall(vim.fs.rm, src, { recursive = true, force = true })
        end
        if ok then
          rename_buffers(src, dst)
        end
      else
        ok = copy(src, dst)
      end
      if not ok then
        notify('failed to paste ' .. src, vim.log.levels.ERROR)
      end
      last = name
    end
  end
  if S.clip.cut then
    S.clip = nil
  end
  refresh(last)
end

function actions.paste()
  paste(false)
end

function actions.paste_force()
  paste(true)
end

function actions.toggle_mark()
  assert(S)
  local e = hovered()
  if not e then
    return
  end
  local path = join(S.cwd, e.name)
  S.marks[path] = not S.marks[path] or nil
  local row = api.nvim_win_get_cursor(S.wins.cur)[1]
  fill(S.bufs.cur, S.entries, S.cwd)
  api.nvim_win_set_cursor(S.wins.cur, { math.min(row + 1, #S.entries), 0 })
end

function actions.select_all()
  assert(S)
  for _, e in ipairs(S.entries) do
    S.marks[join(S.cwd, e.name)] = true
  end
  refresh()
end

function actions.invert()
  assert(S)
  for _, e in ipairs(S.entries) do
    local p = join(S.cwd, e.name)
    S.marks[p] = not S.marks[p] or nil
  end
  refresh()
end

function actions.escape()
  assert(S)
  if next(S.marks) then
    S.marks = {}
    refresh()
  elseif S.filter then
    S.filter = nil
    refresh()
  else
    M.close()
  end
end

function actions.toggle_hidden()
  assert(S)
  S.hidden = not S.hidden
  refresh()
end

local function move(delta)
  assert(S)
  if #S.entries == 0 then
    return
  end
  local row = api.nvim_win_get_cursor(S.wins.cur)[1]
  row = math.max(1, math.min(#S.entries, row + delta))
  api.nvim_win_set_cursor(S.wins.cur, { row, 0 })
end

function actions.down()
  move(vim.v.count1)
end
function actions.up()
  move(-vim.v.count1)
end
function actions.down5()
  move(5)
end
function actions.up5()
  move(-5)
end
function actions.half_down()
  move(math.floor(api.nvim_win_get_height(assert(S).wins.cur) / 2))
end
function actions.half_up()
  move(-math.floor(api.nvim_win_get_height(assert(S).wins.cur) / 2))
end
function actions.top()
  move(-math.huge)
end
function actions.bottom()
  move(math.huge)
end

function actions.home()
  cd(assert(uv.os_homedir()))
end

function actions.go_cwd()
  cd(assert(uv.cwd()))
end

local function find(backward)
  assert(S)
  local pat = S.search
  if not pat or pat == '' or #S.entries == 0 then
    return
  end
  local row = api.nvim_win_get_cursor(S.wins.cur)[1]
  local n = #S.entries
  for i = 1, n do
    local r = ((row - 1 + (backward and -i or i)) % n) + 1
    if S.entries[r].name:lower():find(pat:lower(), 1, true) then
      api.nvim_win_set_cursor(S.wins.cur, { r, 0 })
      return
    end
  end
  notify('no match for ' .. pat, vim.log.levels.WARN)
end

function actions.search()
  local s = input('Find: ')
  if s and s ~= '' then
    assert(S).search = s
    find(false)
  end
end

function actions.search_back()
  local s = input('Find backward: ')
  if s and s ~= '' then
    assert(S).search = s
    find(true)
  end
end

function actions.next()
  find(false)
end

function actions.prev()
  find(true)
end

function actions.filter()
  assert(S)
  local s = input('Filter: ', S.filter)
  if s then
    S.filter = s ~= '' and s or nil
    refresh()
  end
end

---@param what 'path'|'dir'|'name'|'stem'
local function copy_path(what)
  local paths = targets()
  local out = {}
  for _, p in ipairs(paths) do
    out[#out + 1] = what == 'dir' and vim.fs.dirname(p)
      or what == 'name' and vim.fs.basename(p)
      or what == 'stem' and fn.fnamemodify(p, ':t:r')
      or p
  end
  local text = table.concat(out, '\n')
  fn.setreg('"', text)
  pcall(fn.setreg, '+', text)
  notify('copied ' .. text)
end

function actions.shell()
  assert(S)
  local cmd = input('Shell: ')
  if not cmd or cmd == '' then
    return
  end
  local paths = vim.tbl_map(fn.shellescape, targets())
  -- Like yazi: "$@" (or "$0") are the selected/hovered files.
  local full = cmd:gsub('%$@', table.concat(paths, ' ')):gsub('%$0', paths[1] or '')
  local argv = { vim.o.shell, vim.o.shellcmdflag, full }
  local r = vim.system(argv, { cwd = S.cwd, text = true }):wait()
  local out = vim.trim((r.stdout or '') .. (r.stderr or ''))
  if out ~= '' then
    notify(out, r.code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR)
  end
  refresh()
end

function actions.reload()
  refresh()
end

function actions.open()
  enter('edit')
end

function actions.open_split()
  enter('split')
end

function actions.open_vsplit()
  enter('vsplit')
end

function actions.open_tab()
  enter('tab')
end

function actions.help()
  assert(S)
  local lines = {
    'Explorer keys (yazi):',
    '',
    'j/k, J/K       down/up (5)       gg/G  top/bottom',
    'h/l, ←/→       parent / open     <CR>  open',
    '<C-d>/<C-u>    half page         ~     home     g.  cwd',
    '<Space>        select            <C-a> select all',
    '<C-r>          invert selection  <Esc> clear / close',
    'a              create (dir/)     r     rename',
    'd              trash             D     delete permanently',
    'y / x          yank / cut        p/P   paste / overwrite',
    'Y, X           cancel yank/cut   .     toggle hidden',
    '/ ?  n N       find              f     filter',
    'cc cd cf cn    copy path/dir/name/stem',
    ';              shell ($@ = files)  R  reload',
    '<C-s> <C-v> <C-t>  open in split/vsplit/tab',
    'q              quit',
  }
  local buf = S.bufs.prev
  vim.bo[buf].modifiable = true
  pcall(vim.treesitter.stop, buf)
  vim.bo[buf].syntax = ''
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

--- Key → action. Matches yazi's default keymap where it makes sense.
M.keys = {
  { { 'j', '<Down>' }, 'down' },
  { { 'k', '<Up>' }, 'up' },
  { 'J', 'down5' },
  { 'K', 'up5' },
  { '<C-d>', 'half_down' },
  { '<C-u>', 'half_up' },
  { 'gg', 'top' },
  { 'G', 'bottom' },
  { { 'h', '<Left>', '-' }, 'parent' },
  { { 'l', '<Right>', 'o', 'e' }, 'enter' },
  { '<CR>', 'open' },
  { '<C-s>', 'open_split' },
  { '<C-v>', 'open_vsplit' },
  { '<C-t>', 'open_tab' },
  { '<Space>', 'toggle_mark' },
  { '<C-a>', 'select_all' },
  { '<C-r>', 'invert' },
  { '<Esc>', 'escape' },
  { { 'q', '<C-c>' }, 'quit' },
  { 'a', 'create' },
  { 'r', 'rename' },
  { 'd', 'trash' },
  { 'D', 'delete' },
  { 'y', 'yank' },
  { 'x', 'cut' },
  { { 'Y', 'X' }, 'unyank' },
  { 'p', 'paste' },
  { 'P', 'paste_force' },
  { '.', 'toggle_hidden' },
  { '~', 'home' },
  { 'g.', 'go_cwd' },
  { '/', 'search' },
  { '?', 'search_back' },
  { 'n', 'next' },
  { 'N', 'prev' },
  { 'f', 'filter' },
  { 'cc', 'copy_path' },
  { 'cd', 'copy_dir' },
  { 'cf', 'copy_name' },
  { 'cn', 'copy_stem' },
  { ';', 'shell' },
  { 'R', 'reload' },
  { '<F1>', 'help' },
}

actions.parent = leave
actions.enter = function()
  enter('edit')
end
actions.quit = M.close
actions.copy_path = function()
  copy_path('path')
end
actions.copy_dir = function()
  copy_path('dir')
end
actions.copy_name = function()
  copy_path('name')
end
actions.copy_stem = function()
  copy_path('stem')
end

M.actions = actions

local function setup_keys(buf)
  -- Disable everything else (Helix/Vim editing keys) in the listing.
  local disabled = { 'i', 'I', 'A', 'O', 's', 'S', 'u', 'U', 'v', 'V', 'w', 'b', 'm', 'z', 'Z' }
  for _, k in ipairs(disabled) do
    vim.keymap.set('n', k, '<Nop>', { buffer = buf, nowait = true })
  end
  for _, m in ipairs(M.keys) do
    local keys = type(m[1]) == 'table' and m[1] or { m[1] }
    local name = m[2]
    for _, lhs in ipairs(keys) do
      vim.keymap.set('n', lhs, function()
        local ok, err = pcall(actions[name])
        if not ok then
          notify(tostring(err), vim.log.levels.ERROR)
        end
      end, { buffer = buf, nowait = true, desc = 'explorer: ' .. name })
    end
  end
end

local function scratch(name)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  pcall(api.nvim_buf_set_name, buf, name)
  return buf
end

local function layout()
  local cols, lines = vim.o.columns, vim.o.lines
  local width = math.max(40, math.floor(cols * 0.9))
  local height = math.max(6, math.floor(lines * 0.8) - 2)
  local row = math.floor((lines - height) / 2) - 1
  local col = math.floor((cols - width) / 2)
  local w1 = math.floor(width * 0.2)
  local w2 = math.floor(width * 0.35)
  local w3 = width - w1 - w2 - 4
  return {
    parent = { row = row, col = col, width = w1, height = height },
    cur = { row = row, col = col + w1 + 2, width = w2, height = height },
    prev = { row = row, col = col + w1 + w2 + 4, width = math.max(1, w3), height = height },
  }
end

--- Opens the explorer in `dir`, hovering `select` (a file name in `dir`).
---@param dir? string Directory (default: current working directory).
---@param select? string
function M.open(dir, select)
  if S then
    M.close()
  end
  dir = vim.fs.normalize(fn.fnamemodify(dir or assert(uv.cwd()), ':p'))
  if dir ~= '/' then
    dir = dir:gsub('/$', '')
  end
  if fn.isdirectory(dir) == 0 then
    notify('not a directory: ' .. dir, vim.log.levels.ERROR)
    return
  end
  local border = vim.o.winborder ~= '' and vim.o.winborder or 'rounded'
  local L = layout()
  S = {
    cwd = dir,
    entries = {},
    hidden = persist.hidden,
    marks = {},
    clip = persist.clip,
    pos = {},
    origin_win = api.nvim_get_current_win(),
    bufs = {
      parent = scratch('[explorer parent]'),
      cur = scratch('[explorer]'),
      prev = scratch('[explorer preview]'),
    },
    wins = {}, ---@diagnostic disable-line: missing-fields
  }
  for _, k in ipairs({ 'parent', 'prev', 'cur' }) do
    local cfg = vim.tbl_extend('force', L[k], {
      relative = 'editor',
      style = 'minimal',
      border = border,
      focusable = k == 'cur',
      zindex = 150,
    })
    if k == 'prev' then
      cfg.title = ' <F1> help '
      cfg.title_pos = 'right'
    end
    S.wins[k] = api.nvim_open_win(S.bufs[k], k == 'cur', cfg)
    vim.wo[S.wins[k]].cursorline = k ~= 'prev'
    vim.wo[S.wins[k]].wrap = false
    vim.wo[S.wins[k]].winhighlight = 'NormalFloat:Normal,CursorLine:Visual'
  end
  vim.wo[S.wins.prev].number = true
  vim.bo[S.bufs.cur].filetype = 'explorer'
  setup_keys(S.bufs.cur)
  local group = api.nvim_create_augroup('nvim.explorer', {})
  api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = S.bufs.cur,
    callback = function()
      preview()
    end,
  })
  api.nvim_create_autocmd('WinLeave', {
    group = group,
    buffer = S.bufs.cur,
    callback = function()
      -- Leaving the explorer (e.g. a mouse click elsewhere) closes it.
      vim.schedule(function()
        if S and api.nvim_get_current_win() ~= S.wins.cur then
          S.origin_win = api.nvim_get_current_win()
          M.close()
        end
      end)
    end,
  })
  api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      if not S then
        return true
      end
      local L2 = layout()
      for k, w in pairs(S.wins) do
        if api.nvim_win_is_valid(w) then
          api.nvim_win_set_config(w, vim.tbl_extend('force', L2[k], { relative = 'editor' }))
        end
      end
    end,
  })
  refresh(select)
end

--- Opens the explorer at the directory of the current file, hovering it.
function M.open_current()
  local name = api.nvim_buf_get_name(0)
  if name ~= '' and fn.filereadable(name) == 1 then
    M.open(vim.fs.dirname(name), vim.fs.basename(name))
  else
    M.open()
  end
end

--- Whether the explorer is open.
function M.is_open()
  return S ~= nil
end

--- Current directory of the open explorer.
function M.cwd()
  return S and S.cwd
end

return M
