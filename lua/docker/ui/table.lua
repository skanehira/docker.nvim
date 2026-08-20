--- Column alignment for the list.
---
--- Widths are computed with the display width (`strdisplaywidth`). For full-width
--- characters the byte length and the display width differ, so padding by byte length
--- would misalign the columns.
--- Highlight ranges, on the other hand, are handled as byte positions (extmarks take
--- byte positions).
--- Cutting a value down to a width is not part of the padding. `truncate` is a separate step
--- the caller applies before the widths are computed.
local M = {}

--- The separator between columns.
local SEPARATOR = "  "

---@param value string
---@return integer
local function display_width(value)
  return vim.fn.strdisplaywidth(value)
end

--- The marker put at the end of a value that was cut.
local ELLIPSIS = "…"

--- Cut a value down so that it fits into `max_width` display columns.
--- The ellipsis is counted in, so the result never exceeds `max_width`. Cutting happens on a
--- character boundary, which leaves the result one column short when a full-width character
--- does not fit; the padding in `format_row` fills that in, so the columns still line up.
---@param value string
---@param max_width integer
---@return string
function M.truncate(value, max_width)
  if display_width(value) <= max_width then
    return value
  end

  local budget = math.max(max_width - display_width(ELLIPSIS), 0)
  local kept = 0
  for index = 1, vim.fn.strchars(value) do
    if display_width(vim.fn.strcharpart(value, 0, index)) > budget then
      break
    end
    kept = index
  end

  return vim.fn.strcharpart(value, 0, kept) .. ELLIPSIS
end

--- Decide the display width of each column by looking at the headers and every row.
---@param headers string[]
---@param rows string[][]
---@return integer[]
function M.compute_widths(headers, rows)
  local widths = {}
  for index, header in ipairs(headers) do
    widths[index] = display_width(header)
  end

  for _, row in ipairs(rows) do
    for index, value in ipairs(row) do
      local width = display_width(value)
      if width > (widths[index] or 0) then
        widths[index] = width
      end
    end
  end

  return widths
end

--- Pad the values of one row to the given widths and concatenate them.
--- Values longer than the given width are not truncated (that would make IDs and names
--- unreadable, so misalignment is accepted instead).
--- No trailing padding is left at the end of the line (it would make cursor movement and
--- the selection range disagree with what is displayed).
---@param values string[]
---@param widths integer[]
---@return string
function M.format_row(values, widths)
  local parts = {}
  for index, value in ipairs(values) do
    if index == #values then
      table.insert(parts, value)
    else
      local pad = (widths[index] or 0) - display_width(value)
      table.insert(parts, value .. string.rep(" ", math.max(pad, 0)))
    end
  end
  return (table.concat(parts, SEPARATOR):gsub("%s+$", ""))
end

--- Return the byte range that the given column occupies within the row.
--- Byte positions rather than display widths are returned, because they are passed to an extmark.
---@param values string[]
---@param widths integer[]
---@param index integer 1-based column number
---@return integer from Start byte position (0-based)
---@return integer to   End byte position (exclusive)
function M.column_span(values, widths, index)
  local from = 0
  for i = 1, index - 1 do
    local value = values[i] or ""
    local pad = (widths[i] or 0) - display_width(value)
    from = from + #value + math.max(pad, 0) + #SEPARATOR
  end
  return from, from + #(values[index] or "")
end

return M
