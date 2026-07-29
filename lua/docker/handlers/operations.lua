--- 実行中操作の台帳。
---
--- 同一対象への同種の操作は同時に 1 つまでとする (BR-009)。docker 側のロックには
--- 依存せず、ここで受け付けを判断する。
local M = {}

--- 対象 ID -> 操作名 -> true
---@type table<string, table<string, boolean>>
local running = {}

--- テスト用。台帳を空に戻す。
function M._reset()
  running = {}
end

--- 操作の開始を申し出る。既に同じ操作が実行中なら受け付けない。
---@param target_id string
---@param operation string
---@return boolean accepted 受け付けたか
function M.begin(target_id, operation)
  local per_target = running[target_id]
  if per_target and per_target[operation] then
    return false
  end
  if not per_target then
    per_target = {}
    running[target_id] = per_target
  end
  per_target[operation] = true
  return true
end

--- 操作の完了を記録する。
---@param target_id string
---@param operation string
function M.finish(target_id, operation)
  local per_target = running[target_id]
  if not per_target then
    return
  end
  per_target[operation] = nil
  if next(per_target) == nil then
    running[target_id] = nil
  end
end

---@param target_id string
---@param operation string
---@return boolean
function M.is_running(target_id, operation)
  local per_target = running[target_id]
  return (per_target ~= nil and per_target[operation] == true)
end

--- 対象に実行中の操作が 1 つでもあるか (一覧の実行中表示に使う)。
---@param target_id string
---@return boolean
function M.has_any(target_id)
  return running[target_id] ~= nil
end

return M
