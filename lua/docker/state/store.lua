--- リソースストア。種別ごとに一覧を保持し、変化を購読者へ伝える。
---
--- ストアはビューを知らない (Observer)。描画は購読側が状態から投影する。
local M = {}

--- 種別 -> 要素の配列 (取得順を保つ)
---@type table<string, table[]>
local items_by_kind = {}

---@type table<integer, fun(kind: string)>
local listeners = {}
local next_listener_id = 1

--- テスト用。ストアと購読者を初期状態に戻す。
function M._reset()
  items_by_kind = {}
  listeners = {}
  next_listener_id = 1
end

---@param kind string
local function notify_listeners(kind)
  -- 通知中に購読解除されても走査が壊れないよう、呼ぶ前に控えを取る。
  local current = {}
  for id, listener in pairs(listeners) do
    current[id] = listener
  end
  for _, listener in pairs(current) do
    listener(kind)
  end
end

---@param kind string
---@return table[]
local function bucket(kind)
  local existing = items_by_kind[kind]
  if not existing then
    existing = {}
    items_by_kind[kind] = existing
  end
  return existing
end

---@param list table[]
---@param id string
---@return integer|nil
local function index_of(list, id)
  for index, item in ipairs(list) do
    if item.id == id then
      return index
    end
  end
  return nil
end

--- 一覧取得の結果で種別の内容を全置換する。
---@param kind string
---@param items table[]
function M.replace_all(kind, items)
  items_by_kind[kind] = vim.deepcopy(items)
  notify_listeners(kind)
end

--- 1 件を追加または更新する。同一種別に同一 ID を重複させない (INV-1)。
---@param kind string
---@param item table
function M.upsert(kind, item)
  local list = bucket(kind)
  local index = index_of(list, item.id)
  if index then
    list[index] = vim.deepcopy(item)
  else
    table.insert(list, vim.deepcopy(item))
  end
  notify_listeners(kind)
end

--- 1 件を取り除く。存在しない場合は何もせず通知もしない。
---@param kind string
---@param id string
function M.remove(kind, id)
  local list = bucket(kind)
  local index = index_of(list, id)
  if not index then
    return
  end
  table.remove(list, index)
  notify_listeners(kind)
end

--- 種別の一覧を返す。返した配列を変更してもストアには影響しない。
---@param kind string
---@return table[]
function M.list(kind)
  return vim.deepcopy(items_by_kind[kind] or {})
end

--- 状態変化を購読する。
---@param listener fun(kind: string)
---@return fun() 購読解除
function M.subscribe(listener)
  local id = next_listener_id
  next_listener_id = next_listener_id + 1
  listeners[id] = listener
  return function()
    listeners[id] = nil
  end
end

return M
