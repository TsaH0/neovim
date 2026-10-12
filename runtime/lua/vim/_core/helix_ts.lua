--- @brief
--- Tree-sitter helpers for Helix mode: syntax-node selection (Alt-o, Alt-i,
--- …), textobjects (`maf`, `mit`, …) and node navigation (`]f`, `[t`, …).
---
--- Helix uses textobject queries; Nvim doesn't ship those, so node kinds are
--- recognized by type-name heuristics that work across most grammars.

local sel = require('vim._core.helix_sel')

local M = {}

--- Node-type patterns per textobject kind.
local kinds = {
  ['function'] = {
    'function',
    'method',
    'lambda',
    'closure',
    'arrow_function',
    'func_literal',
    'constructor_declaration',
  },
  class = {
    'class',
    'struct',
    'interface',
    'enum',
    'trait',
    'impl_item',
    'type_definition',
    'type_declaration',
    'type_alias',
    'union',
    'module',
  },
  parameter = { 'parameter', 'argument' },
  comment = { 'comment' },
  entry = { 'pair', 'field', 'key_value', 'entry', 'property', 'table_constructor_field' },
  xml = { 'element', 'jsx_element', 'jsx_self_closing_element', 'tag' },
}
-- Containers of parameters/arguments: their named children are the items.
local param_lists = {
  'parameters',
  'parameter_list',
  'arguments',
  'argument_list',
  'formal_parameters',
  'type_arguments',
  'type_parameters',
}
local body_fields = { 'body', 'block', 'value', 'consequence' }

---@param type string
---@param pats string[]
local function matches(type, pats)
  for _, p in ipairs(pats) do
    if type:find(p, 1, true) then
      return true
    end
  end
  return false
end

--- Is `node` of textobject `kind`?
---@param node TSNode
---@param kind string
local function is_kind(node, kind)
  local t = node:type()
  if kind == 'test' then
    if not is_kind(node, 'function') then
      return false
    end
    local text = vim.treesitter.get_node_text(node, 0):sub(1, 200)
    return text:lower():find('test') ~= nil
  elseif kind == 'parameter' then
    local p = node:parent()
    return node:named() and p ~= nil and matches(p:type(), param_lists)
  elseif kind == 'function' then
    -- Skip "function_call", "method_invocation", … and names.
    if t:find('call') or t:find('invocation') or t:find('name') or t:find('identifier') then
      return false
    end
    if t:find('parameter') or t:find('type') or t == 'function' and not node:named() then
      return false
    end
  elseif kind == 'class' then
    if t:find('identifier') or t:find('name') or t:find('body') then
      return false
    end
  end
  return matches(t, kinds[kind] or {})
end

---@return TSNode?
local function root()
  local ok, parser = pcall(vim.treesitter.get_parser, 0, nil, { error = false })
  if not ok or not parser then
    return nil
  end
  local tree = parser:parse(true)
  if not tree or not tree[1] then
    return nil
  end
  -- Prefer the deepest language tree at the cursor (injections).
  local c = vim.api.nvim_win_get_cursor(0)
  local lt = parser:language_for_range({ c[1] - 1, c[2], c[1] - 1, c[2] })
  local t = lt:tree_for_range({ c[1] - 1, c[2], c[1] - 1, c[2] })
  return (t or tree[1]):root()
end

function M.available()
  return root() ~= nil
end

--- Converts a node range to a selection.
---@param node TSNode
---@return nvim.helix.Sel
function M.node_sel(node)
  local sr, sc, er, ec = node:range()
  local a = sel.clamp({ sr, sc })
  local h = sel.prev({ er, ec }) or a
  if sel.cmp(h, a) < 0 then
    h = a
  end
  return { a = a, h = sel.clamp(h) }
end

--- Smallest named node covering selection `s`.
---@param s nvim.helix.Sel
---@return TSNode?
function M.node_for(s)
  local r = root()
  if not r then
    return nil
  end
  local f, e = sel.from(s), sel.after(sel.to(s))
  return r:named_descendant_for_range(f[1], f[2], e[1], e[2])
end

local function same_range(node, s)
  local ns = M.node_sel(node)
  return sel.cmp(ns.a, sel.from(s)) == 0 and sel.cmp(ns.h, sel.to(s)) == 0
end

--- Alt-o: parent node strictly larger than `s`.
---@param s nvim.helix.Sel
---@return nvim.helix.Sel?
function M.expand(s)
  local node = M.node_for(s)
  while node and same_range(node, s) do
    node = node:parent()
  end
  return node and M.node_sel(node)
end

--- Alt-i: first named child smaller than `s`.
---@param s nvim.helix.Sel
---@return nvim.helix.Sel?
function M.shrink(s)
  local node = M.node_for(s)
  if not node then
    return nil
  end
  local child = node:named_child(0)
  while child and same_range(child, s) do
    child = child:named_child(0)
  end
  return child and M.node_sel(child)
end

--- Alt-n / Alt-p: next/prev named sibling.
---@param s nvim.helix.Sel
---@param forward boolean
---@return nvim.helix.Sel?
function M.sibling(s, forward)
  local node = M.node_for(s)
  while node do
    local sib = forward and node:next_named_sibling() or node:prev_named_sibling()
    if sib then
      return M.node_sel(sib)
    end
    node = node:parent()
  end
end

--- Alt-a: all named siblings (children of the parent).
---@param s nvim.helix.Sel
---@return nvim.helix.Sel[]?
function M.all_siblings(s)
  local node = M.node_for(s)
  local parent = node and node:parent()
  if not parent then
    return nil
  end
  local out = {}
  for child in parent:iter_children() do
    if child:named() then
      out[#out + 1] = M.node_sel(child)
    end
  end
  return out
end

--- Alt-I: all named children of the node.
---@param s nvim.helix.Sel
---@return nvim.helix.Sel[]?
function M.all_children(s)
  local node = M.node_for(s)
  if not node then
    return nil
  end
  local out = {}
  for child in node:iter_children() do
    if child:named() then
      out[#out + 1] = M.node_sel(child)
    end
  end
  return #out > 0 and out or nil
end

--- Alt-b / Alt-e: start/end of the parent node.
---@param s nvim.helix.Sel
---@param to_end boolean
---@return nvim.helix.Pos?
function M.parent_edge(s, to_end)
  local node = M.node_for(s)
  node = node and (same_range(node, s) and node:parent() or node)
  if not node then
    return nil
  end
  local ns = M.node_sel(node)
  return to_end and ns.h or ns.a
end

--- Inner part of a textobject node.
---@param node TSNode
---@param kind string
---@return nvim.helix.Sel
local function inner(node, kind)
  if kind == 'function' or kind == 'class' or kind == 'test' then
    for _, f in ipairs(body_fields) do
      local b = node:field(f)[1]
      if b then
        node = b
        break
      end
    end
    -- Strip the braces of a block body.
    local n = node:named_child_count()
    if n > 0 then
      local first, last = node:named_child(0), node:named_child(n - 1)
      local s1 = M.node_sel(assert(first))
      local s2 = M.node_sel(assert(last))
      return { a = s1.a, h = s2.h }
    end
  elseif kind == 'comment' then
    local s = M.node_sel(node)
    local text = vim.treesitter.get_node_text(node, 0)
    local lead = #(text:match('^[%-/#%*;!%s]*') or '')
    local trail = #(text:match('[%-/%*%s]*$') or '')
    if lead + trail < #text and not text:find('\n') then
      return { a = { s.a[1], s.a[2] + lead }, h = { s.h[1], s.h[2] - trail } }
    end
    return s
  end
  return M.node_sel(node)
end

--- `ma<obj>` / `mi<obj>`: smallest textobject node of `kind` around `s`.
---@param s nvim.helix.Sel
---@param kind string
---@param around boolean
---@return nvim.helix.Sel?
function M.textobject(s, kind, around)
  local node = M.node_for(s)
  while node do
    if is_kind(node, kind) then
      if around then
        return M.node_sel(node)
      end
      return inner(node, kind)
    end
    node = node:parent()
  end
end

--- `]f`, `[t`, …: next/previous node of `kind` after/before `pos`.
---@param pos nvim.helix.Pos
---@param kind string
---@param forward boolean
---@return nvim.helix.Sel?
function M.goto_kind(pos, kind, forward)
  local r = root()
  if not r then
    return nil
  end
  local best ---@type TSNode?
  local function visit(node)
    if is_kind(node, kind) then
      local sr, sc = node:start()
      local c = sel.cmp({ sr, sc }, pos)
      if forward and c > 0 then
        local br, bc = 0, 0
        if best then
          br, bc = best:start()
        end
        if not best or sel.cmp({ sr, sc }, { br, bc }) < 0 then
          best = node
        end
      elseif not forward and c < 0 then
        local br, bc = 0, 0
        if best then
          br, bc = best:start()
        end
        if not best or sel.cmp({ sr, sc }, { br, bc }) > 0 then
          best = node
        end
      end
    end
    for child in node:iter_children() do
      if child:named() then
        visit(child)
      end
    end
  end
  visit(r)
  return best and M.node_sel(best)
end

--- `mm`: matching bracket via the syntax tree (falls back to `%`).
---@param p nvim.helix.Pos
---@return nvim.helix.Pos?
function M.match_bracket(p)
  local r = root()
  if not r then
    return nil
  end
  local node = r:descendant_for_range(p[1], p[2], p[1], p[2] + 1)
  if not node or node:named() then
    return nil
  end
  local parent = node:parent()
  if not parent then
    return nil
  end
  local first, last = parent:child(0), parent:child(parent:child_count() - 1)
  if not first or not last then
    return nil
  end
  if node:equal(first) then
    return M.node_sel(last).h
  elseif node:equal(last) then
    return M.node_sel(first).a
  end
end

return M
