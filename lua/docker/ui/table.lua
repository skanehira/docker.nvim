--- 一覧の桁揃え。
---
--- 幅の計算は表示幅 (`strdisplaywidth`) で行う。全角文字はバイト長と表示幅が
--- 一致しないため、バイト長で詰めると列がずれる。
--- 一方でハイライトの範囲はバイト位置で扱う (extmark がバイト位置を取るため)。
local M = {}

--- 列と列の区切り。
local SEPARATOR = "  "

---@param value string
---@return integer
local function display_width(value)
  return vim.fn.strdisplaywidth(value)
end

--- 見出しと全行を見て、各列の表示幅を決める。
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

--- 1 行分の値を指定幅に揃えて連結する。
--- 指定幅より長い値は切り詰めない (ID や名前が読めなくなるため、桁ずれを許容する)。
--- 行末の余白は残さない (カーソル移動と選択範囲が見た目とずれるため)。
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

--- 指定した列が行内で占めるバイト範囲を返す。
--- extmark に渡すため、表示幅ではなくバイト位置で返す。
---@param values string[]
---@param widths integer[]
---@param index integer 1 始まりの列番号
---@return integer from 開始バイト位置 (0 始まり)
---@return integer to   終了バイト位置 (この位置は含まない)
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
