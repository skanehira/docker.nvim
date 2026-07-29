--- 一覧ビュー。リソース集合をバッファ行へ投影する。
---
--- 見出しはバッファに入れず `winbar` に置く。カーソル行とデータ行の添字が
--- 1 対 1 になり、行番号の補正が要らなくなる。
local highlight = require("docker.ui.highlight")
local tbl = require("docker.ui.table")
local window = require("docker.ui.window")

local M = {}

---@class docker.ListBuild
---@field lines string[]      バッファに入れる行
---@field winbar string       見出し行
---@field rows string[][]     行ごとの列の値 (ハイライト範囲の算出に使う)
---@field widths integer[]    列の表示幅
---@field empty boolean       表示するリソースが 0 件か

---@param def docker.ResourceDefinition
---@return string[]
local function headers_of(def)
  local headers = {}
  for _, column in ipairs(def.columns) do
    table.insert(headers, column.header)
  end
  return headers
end

--- リソース集合からバッファ行と見出しを組み立てる。
---@param def docker.ResourceDefinition
---@param items table[]
---@return docker.ListBuild
function M.build(def, items)
  local headers = headers_of(def)

  local rows = {}
  for _, item in ipairs(items) do
    local values = {}
    for _, column in ipairs(def.columns) do
      table.insert(values, column.value(item))
    end
    table.insert(rows, values)
  end

  local widths = tbl.compute_widths(headers, rows)

  local lines = {}
  for _, values in ipairs(rows) do
    table.insert(lines, tbl.format_row(values, widths))
  end

  -- 0 件でも見出しは出し、本文に「無い」ことを 1 行で示す。
  -- エラーと区別が付くようにするため、空のバッファにはしない。
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

--- カーソル行に対応するリソースを返す。
---@param items table[]
---@param lnum integer 1 始まりの行番号
---@return table|nil
function M.item_at(items, lnum)
  if type(lnum) ~= "number" or lnum < 1 then
    return nil
  end
  return items[lnum]
end

--- ウィンドウへ描画する。状態カラムには状態別のハイライトを付ける。
---@param handle docker.Window
---@param def docker.ResourceDefinition
---@param items table[]
---@return docker.ListBuild
function M.render(handle, def, items)
  local built = M.build(def, items)

  window.set_lines(handle, built.lines)
  if vim.api.nvim_win_is_valid(handle.winid) then
    vim.wo[handle.winid].winbar = built.winbar
  end

  highlight.clear(handle.bufnr)
  if not built.empty and def.status_column then
    for index, values in ipairs(built.rows) do
      local from, to = tbl.column_span(values, built.widths, def.status_column)
      highlight.apply(handle.bufnr, index - 1, from, to, highlight.group_for(def.status(items[index])))
    end
  end

  return built
end

return M
