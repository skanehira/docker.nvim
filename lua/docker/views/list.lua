--- List view. Projects a set of resources onto buffer lines.
---
--- Headers are not put into the buffer but into the `winbar`. This makes the cursor
--- line and the data row index map one to one, so no line number adjustment is needed.
local highlight = require("docker.ui.highlight")
local tbl = require("docker.ui.table")
local window = require("docker.ui.window")

local M = {}

---@class docker.ListBuild
---@field lines string[]      Lines to put into the buffer
---@field winbar string       Header line
---@field rows string[][]     Column values per row (used to compute the highlight ranges)
---@field widths integer[]    Display width of each column
---@field empty boolean       Whether there are zero resources to show

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

--- Build the buffer lines and the header from a set of resources.
---@param def docker.ResourceDefinition
---@param items table[]
---@param opts { busy: fun(item: table): boolean }|nil Predicate telling whether the resource is busy
---@return docker.ListBuild
function M.build(def, items, opts)
  local headers = headers_of(def)
  local busy = opts and opts.busy

  local rows = {}
  for _, item in ipairs(items) do
    local values = {}
    for index, column in ipairs(def.columns) do
      local value = single_line(column.value(item))
      if busy and index == def.status_column and busy(item) then
        value = value .. BUSY_SUFFIX
      end
      table.insert(values, value)
    end
    table.insert(rows, values)
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
  }
end

--- Return the resource that corresponds to the cursor line.
---@param items table[]
---@param lnum integer 1-based line number
---@return table|nil
function M.item_at(items, lnum)
  if type(lnum) ~= "number" or lnum < 1 then
    return nil
  end
  return items[lnum]
end

--- Render into the window. The status column gets a highlight that depends on the state.
---@param handle docker.Window
---@param def docker.ResourceDefinition
---@param items table[]
---@param opts { busy: fun(item: table): boolean }|nil
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
  local status_of = def.status
  if not built.empty and def.status_column and status_of then
    for index, values in ipairs(built.rows) do
      local from, to = tbl.column_span(values, built.widths, def.status_column)
      highlight.apply(handle.bufnr, index - 1, from, to, highlight.group_for(status_of(items[index])))
    end
  end

  return built
end

return M
