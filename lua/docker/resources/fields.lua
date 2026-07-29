--- 一覧取得の生データから表示に使う値を取り出すヘルパ。
---
--- compose 由来かの判定はここに集約する。ラベルは `.Label` によるキー名指しで
--- 採取済みなので、値に偽のラベルが仕込まれていても空文字列のまま扱える。
local M = {}

--- `docker compose run` が作る単発コンテナに付く値。
local ONEOFF_TRUE = "True"

---@param item table
---@param key string
---@return string
local function str(item, key)
  local value = item[key]
  return type(value) == "string" and value or ""
end

--- compose が作ったコンテナか。
--- プロジェクト名とサービス名が揃っていることを条件にする (DESIGN_DETAIL_APP.md 4.1)。
---@param item table
---@return boolean
function M.is_compose(item)
  return str(item, "compose_project") ~= "" and str(item, "compose_service") ~= ""
end

--- `docker compose run` が作る単発コンテナか (BR-006)。
---@param item table
---@return boolean
function M.is_oneoff(item)
  return str(item, "compose_oneoff") == ONEOFF_TRUE
end

--- サービスの実体としてのコンテナなら、その所属を返す。
--- 単発コンテナはサービスに紐付けない (BR-006)。
---@param item table
---@return { project: string, service: string }|nil
function M.service_of(item)
  if not M.is_compose(item) or M.is_oneoff(item) then
    return nil
  end
  return { project = str(item, "compose_project"), service = str(item, "compose_service") }
end

--- 公開ポートの表示文字列。
---@param item table
---@return string
function M.ports(item)
  return str(item, "ports")
end

--- 状態 (running / exited / paused など)。
---@param item table
---@return string
function M.state(item)
  return str(item, "state")
end

return M
