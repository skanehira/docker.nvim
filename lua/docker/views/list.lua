--- List view. Projects a set of resources onto buffer lines.
---
--- Headers are not put into the buffer but into the `winbar`. This makes the cursor
--- line and the data row index map one to one, so no line number adjustment is needed.
---
--- A resource definition may declare `group`. Items are then folded under a header per group.
--- The rows drawn are represented by `docker.ListEntry`, so a line number is not an index into
--- the item array anymore.
local highlight = require("docker.ui.highlight")
local tbl = require("docker.ui.table")
local window = require("docker.ui.window")

local M = {}

---@class docker.ListEntry
---@field values string[]        Column values drawn on this line
---@field item table|nil         The resource on this line (nil for a group header)
---@field group string|nil       The group key on this line (nil for a resource row)
---@field items table[]|nil      The resources in the group (only on a group header)
---@field collapsed boolean|nil  Whether the group is collapsed (only on a group header)

---@class docker.ListBuildOpts
---@field busy? fun(item: table): boolean
---@field collapsed? table<string, boolean>

---@class docker.ListBuild
---@field lines string[]      Lines to put into the buffer
---@field winbar string       Header line
---@field rows string[][]     Column values per row (used to compute the highlight ranges)
---@field widths integer[]    Display width of each column
---@field empty boolean       Whether there are zero resources to show
---@field entries docker.ListEntry[] Rows in display order (group headers and resources)

--- Collapse a value into a single line for display.
---
--- compose label values and container names may contain any character. Even a single
--- value containing a newline makes `nvim_buf_set_lines` fail, so the list itself cannot
--- be drawn. Unless they are flattened before the widths are computed, the column
--- alignment and the highlight byte positions shift as well.
---@param value any
---@return string
local function single_line(value)
  return (tostring(value or ""):gsub("%c", " "))
end

---@param def docker.ResourceDefinition
---@return string[]
local function headers_of(def)
  local headers = {}
  for _, column in ipairs(def.columns) do
    table.insert(headers, column.header)
  end
  return headers
end

--- Marker showing that the resource is busy with an operation.
--- It is appended to the status column instead of adding a new column (G1 fixes the column layout).
local BUSY_SUFFIX = " (busy)"
local BUSY_ONLY = "(busy)"

---@param def docker.ResourceDefinition
---@return (integer|nil)[]
local function max_widths_of(def)
  -- Looked up once per column rather than once per row, since the setting does not change
  -- while a single list is being built.
  local max_widths = {}
  for index, column in ipairs(def.columns) do
    max_widths[index] = column.max_width and column.max_width() or nil
  end
  return max_widths
end

--- The column values of one resource row.
---@param def docker.ResourceDefinition
---@param item table
---@param busy (fun(item: table): boolean)|nil
---@param max_widths (integer|nil)[]
---@return string[]
local function values_of(def, item, busy, max_widths)
  local values = {}
  for index, column in ipairs(def.columns) do
    local value = single_line(column.value(item))
    if busy and index == def.status_column and busy(item) then
      value = value == "" and BUSY_ONLY or (value .. BUSY_SUFFIX)
    end
    -- Cut before the values go into rows. The widths and the highlight byte ranges are
    -- computed from rows, so cutting afterwards would shift them apart.
    if max_widths[index] then
      value = tbl.truncate(value, max_widths[index])
    end
    table.insert(values, value)
  end
  return values
end

--- Build the rows in display order. Items that belong to a group are preceded by a header row.
--- Groups are sorted by key so that the row order stays stable across fetches; items that do not
--- belong to a group follow the grouped rows in the order they were fetched.
---@param def docker.ResourceDefinition
---@param items table[]
---@param opts docker.ListBuildOpts|nil
---@return docker.ListEntry[]
function M.entries(def, items, opts)
  local busy = opts and opts.busy
  local collapsed = (opts and opts.collapsed) or {}
  local max_widths = max_widths_of(def)

  if not def.group then
    local entries = {}
    for _, item in ipairs(items) do
      table.insert(entries, { item = item, values = values_of(def, item, busy, max_widths) })
    end
    return entries
  end

  local groups, order = {}, {}
  local ungrouped = {}
  for _, item in ipairs(items) do
    local key = def.group.key(item)
    if type(key) == "string" and key ~= "" then
      if not groups[key] then
        groups[key] = {}
        table.insert(order, key)
      end
      table.insert(groups[key], item)
    else
      table.insert(ungrouped, item)
    end
  end
  table.sort(order)

  local entries = {}
  for _, key in ipairs(order) do
    local group_items = groups[key]
    local is_collapsed = collapsed[key] == true

    local values = {}
    for index = 1, #def.columns do
      values[index] = ""
    end
    values[1] = single_line(def.group.label(key, is_collapsed))
    -- The busy marker of a project operation is shown on its header row as well.
    if busy and def.status_column and busy({ id = key }) then
      values[def.status_column] = BUSY_ONLY
    end

    table.insert(entries, {
      group = key,
      items = group_items,
      collapsed = is_collapsed,
      values = values,
    })

    if not is_collapsed then
      for _, item in ipairs(group_items) do
        local child_values = values_of(def, item, busy, max_widths)
        -- Indent after cutting: the prefix is presentation, so it does not eat into the
        -- configured width of the value itself.
        if def.group.child_prefix then
          child_values[1] = def.group.child_prefix .. child_values[1]
        end
        table.insert(entries, { item = item, values = child_values })
      end
    end
  end

  for _, item in ipairs(ungrouped) do
    table.insert(entries, { item = item, values = values_of(def, item, busy, max_widths) })
  end

  return entries
end

--- Build the buffer lines and the header from a set of resources.
---@param def docker.ResourceDefinition
---@param items table[]
---@param opts docker.ListBuildOpts|nil
---@return docker.ListBuild
function M.build(def, items, opts)
  local headers = headers_of(def)
  local entries = M.entries(def, items, opts)

  local rows = {}
  for _, entry in ipairs(entries) do
    table.insert(rows, entry.values)
  end

  local widths = tbl.compute_widths(headers, rows)

  local lines = {}
  for _, values in ipairs(rows) do
    table.insert(lines, tbl.format_row(values, widths))
  end

  -- Show the header even with zero items, and state in a single body line that there are none.
  -- The buffer is never left empty, so that this stays distinguishable from an error.
  local empty = #items == 0
  if empty then
    lines = { def.empty_text }
  end

  return {
    lines = lines,
    winbar = tbl.format_row(headers, widths),
    rows = rows,
    widths = widths,
    empty = empty,
    entries = entries,
  }
end

--- Return the resource that corresponds to the cursor line.
--- Kept for ungrouped lists; the grouped list uses `entry_at` so that a group header can be told
--- apart from a resource row.
---@param items table[]
---@param lnum integer 1-based line number
---@return table|nil
function M.item_at(items, lnum)
  if type(lnum) ~= "number" or lnum < 1 then
    return nil
  end
  return items[lnum]
end

--- Return the row that corresponds to the cursor line.
---@param entries docker.ListEntry[]
---@param lnum integer 1-based line number
---@return docker.ListEntry|nil
function M.entry_at(entries, lnum)
  if type(lnum) ~= "number" or lnum < 1 then
    return nil
  end
  return entries[lnum]
end

--- Render into the window. The status column gets a highlight that depends on the state, and
--- a group header is highlighted as a heading.
---@param handle docker.Window
---@param def docker.ResourceDefinition
---@param items table[]
---@param opts docker.ListBuildOpts|nil
---@return docker.ListBuild
function M.render(handle, def, items, opts)
  local built = M.build(def, items, opts)

  -- If the view is closed while fetching, the buffer is already invalid when the result arrives.
  if not vim.api.nvim_buf_is_valid(handle.bufnr) then
    return built
  end

  window.set_lines(handle, built.lines)
  window.set_winbar(handle, built.winbar)

  highlight.clear(handle.bufnr)
  if not built.empty then
    for index, entry in ipairs(built.entries) do
      if entry.group then
        local from, to = tbl.column_span(entry.values, built.widths, 1)
        highlight.apply(handle.bufnr, index - 1, from, to, highlight.group_row_group())
      elseif def.status_column and def.status then
        local from, to = tbl.column_span(entry.values, built.widths, def.status_column)
        highlight.apply(handle.bufnr, index - 1, from, to, highlight.group_for(def.status(entry.item)))
      end
    end
  end

  return built
end

return M
