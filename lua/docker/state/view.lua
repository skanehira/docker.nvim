--- ビュー状態の生成と更新。
---
--- 更新は必ず新しい値を作る (不変更新)。状態を唯一の源として描画を行うため、
--- 途中で書き換わると描画とカーソルの整合が取れなくなる。
local M = {}

---@class docker.ViewState
---@field kind string     リソース種別
---@field items table[]   表示中のリソース
---@field cursor integer  カーソル行 (1 始まり)

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
  return { kind = kind, items = {}, cursor = 1 }
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
  }
end

--- カーソル行のリソース。0 件のときは nil。
---@param state docker.ViewState
---@return table|nil
function M.selected(state)
  return state.items[state.cursor]
end

return M
