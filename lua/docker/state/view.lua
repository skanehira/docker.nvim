--- ビュー状態の生成と更新。
---
--- 更新は必ず新しい値を作る (不変更新)。状態を唯一の源として描画を行うため、
--- 途中で書き換わると描画とカーソルの整合が取れなくなる。
local M = {}

---@class docker.ViewState
---@field kind string     リソース種別
---@field items table[]   表示中のリソース
---@field cursor integer  カーソル行 (1 始まり)
---@field filter string   絞り込みの語 (空なら全件)

---@param count integer
---@param cursor integer
---@return integer
local function clamp_cursor(count, cursor)
  if count == 0 then
    return 1
  end
  return math.max(1, math.min(cursor, count))
end

---@param kind string
---@return docker.ViewState
function M.new(kind)
  return { kind = kind, items = {}, cursor = 1, filter = "" }
end

--- 表示するリソースを差し替える。カーソルは保つが、範囲外になれば丸める。
---@param state docker.ViewState
---@param items table[]
---@return docker.ViewState
function M.with_items(state, items)
  return {
    kind = state.kind,
    items = vim.deepcopy(items),
    cursor = clamp_cursor(#items, state.cursor),
    filter = state.filter or "",
  }
end

--- カーソル行を変える。範囲外の値は丸める。
---@param state docker.ViewState
---@param cursor integer
---@return docker.ViewState
function M.with_cursor(state, cursor)
  return {
    kind = state.kind,
    items = vim.deepcopy(state.items),
    cursor = clamp_cursor(#state.items, cursor),
    filter = state.filter or "",
  }
end

--- 絞り込みの語を差し替える。カーソルは先頭へ戻す (行の対応が変わるため)。
---@param state docker.ViewState
---@param filter string
---@return docker.ViewState
function M.with_filter(state, filter)
  return {
    kind = state.kind,
    items = vim.deepcopy(state.items),
    cursor = 1,
    filter = filter or "",
  }
end

--- 絞り込みを適用した後の項目。
--- 表示に使う値のどれかに部分一致すれば残す (大文字小文字は区別しない)。
---@param state docker.ViewState
---@param def docker.ResourceDefinition
---@return table[]
function M.visible_items(state, def)
  local filter = state.filter or ""
  if filter == "" then
    return state.items
  end

  local needle = filter:lower()
  local matched = {}
  for _, item in ipairs(state.items) do
    for _, column in ipairs(def.columns) do
      if tostring(column.value(item)):lower():find(needle, 1, true) then
        table.insert(matched, item)
        break
      end
    end
  end
  return matched
end

--- カーソル行のリソース。0 件のときは nil。
---@param state docker.ViewState
---@return table|nil
function M.selected(state)
  return state.items[state.cursor]
end

return M
