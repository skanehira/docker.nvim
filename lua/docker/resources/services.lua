--- compose サービス一覧の組み立て。
---
--- 表示はコンテナの実体から作るが、compose.yaml に定義されていて起動していない
--- サービスも一覧に出す (BR-005)。突き合わせはコンテナのラベルで行い、
--- `docker compose run` が作る単発コンテナはサービスの実体として扱わない (BR-006)。
local fields = require("docker.resources.fields")

local M = {}

---@class docker.Service
---@field project string
---@field name string
---@field container string      紐付くコンテナ名 (無ければ空文字列)
---@field container_id string   紐付くコンテナ ID (無ければ空文字列)
---@field status string         コンテナの状態。紐付くコンテナが無ければ "none"

--- 起動していないサービスの状態。
local NONE = "none"

--- compose の定義とコンテナ一覧から、サービスの一覧を組み立てる。
--- 並びは compose の定義順 (呼び出し側で並べ替え済み) を保つ。
---@param project docker.ComposeProject
---@param containers table[]
---@return docker.Service[]
function M.assemble(project, containers)
  --- サービス名 -> 紐付くコンテナ
  local by_service = {}
  for _, item in ipairs(containers) do
    local owner = fields.service_of(item)
    if owner and owner.project == project.name then
      local current = by_service[owner.service]
      -- 同じサービスに複数のコンテナがある場合 (scale) は稼働中のものを代表にする。
      -- 先頭固定だと、レプリカが動いているのに停止として見えることがある。
      if not current or (fields.state(current) ~= "running" and fields.state(item) == "running") then
        by_service[owner.service] = item
      end
    end
  end

  local items = {}
  for _, name in ipairs(project.service_names) do
    local item = by_service[name]
    table.insert(items, {
      project = project.name,
      name = name,
      container = item and item.name or "",
      container_id = item and item.id or "",
      status = item and fields.state(item) or NONE,
    })
  end
  return items
end

return M
