--- ビュー種別からキーマップを解決する。
---
--- 共通のキーにビュー固有のキーを重ねる。同じキーがビュー種別ごとに別の
--- アクションへ割り当てられる (BR-015)。
local config = require("docker.config")

local M = {}

---@param view_type string
---@return table<string, string> キー -> アクション名
function M.resolve(view_type)
  local keymaps = config.get().keymaps
  local resolved = {}

  for action, key in pairs(keymaps.common or {}) do
    resolved[key] = action
  end
  -- ビュー固有が共通と同じキーを使う場合はビュー固有を優先する。
  for action, key in pairs(keymaps[view_type] or {}) do
    resolved[key] = action
  end

  return resolved
end

--- ヘルプ表示のための一覧。キー順に並べる (実行のたびに順序が変わらないように)。
---@param view_type string
---@return { key: string, action: string }[]
function M.describe_view(view_type)
  local resolved = M.resolve(view_type)

  local keys = {}
  for key in pairs(resolved) do
    table.insert(keys, key)
  end
  table.sort(keys)

  local rows = {}
  for _, key in ipairs(keys) do
    table.insert(rows, { key = key, action = resolved[key] })
  end
  return rows
end

return M
