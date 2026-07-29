--- リソース種別の宣言的定義。
---
--- 種別の追加はこのファイルへの定義追加だけで完結させ、ビューとハンドラに
--- 種別ごとの分岐を増やさない (レジストリパターン)。
local fields = require("docker.resources.fields")
local format = require("docker.format")

local M = {}

---@class docker.ColumnDef
---@field header string
---@field value fun(item: table): string

---@class docker.ResourceDefinition
---@field kind string                    "container" | "image" | "volume" | "network" | "service"
---@field subcommand string              `:Docker` に渡す引数 (例: "containers")
---@field display_name string
---@field list_args fun(): string[]      一覧取得の docker 引数
---@field id fun(item: table): string    識別子の取り出し
---@field columns docker.ColumnDef[]
---@field status_column integer|nil      ハイライト対象のカラム位置 (1 始まり)
---@field status fun(item: table): string|nil
---@field event_type string|nil          docker events の Type との対応

--- コンテナ一覧で取得するフィールド。
--- compose ラベルは `.Label` によるキー名指しで取る。`Labels` をまとめて取って
--- 分割してはならない (ラベル値のカンマと、値に偽ラベルを仕込む攻撃の両方で誤読する)。
--- `.Size` は参照しない (サイズ計算が走り実行時間が増える)。
local CONTAINER_FIELDS = {
  { key = "id", expr = ".ID" },
  { key = "name", expr = ".Names" },
  { key = "image", expr = ".Image" },
  { key = "state", expr = ".State" },
  { key = "status", expr = ".Status" },
  { key = "ports", expr = ".Ports" },
  { key = "command", expr = ".Command" },
  { key = "created_at", expr = ".CreatedAt" },
  { key = "compose_project", expr = format.label_expr("com.docker.compose.project") },
  { key = "compose_service", expr = format.label_expr("com.docker.compose.service") },
  { key = "compose_oneoff", expr = format.label_expr("com.docker.compose.oneoff") },
}

---@param key string
---@return fun(item: table): string
local function plain(key)
  return function(item)
    local value = item[key]
    return type(value) == "string" and value or ""
  end
end

---@type table<string, docker.ResourceDefinition>
local definitions = {
  container = {
    kind = "container",
    subcommand = "containers",
    display_name = "Containers",
    -- `-a` は停止中のコンテナも一覧に含めるため (BR-022)。
    -- `--no-trunc` が無いと ID が 12 文字、Command が 20 文字で切り詰められる。
    list_args = function()
      return { "ps", "-a", "--no-trunc", "--format", format.template(CONTAINER_FIELDS) }
    end,
    id = plain("id"),
    columns = {
      { header = "NAME", value = plain("name") },
      { header = "IMAGE", value = plain("image") },
      { header = "STATUS", value = plain("status") },
      { header = "PORTS", value = fields.ports },
      { header = "PROJECT", value = plain("compose_project") },
      { header = "SERVICE", value = plain("compose_service") },
    },
    status_column = 3,
    status = fields.state,
    event_type = "container",
  },
}

--- `:Docker` のサブコマンドとして受け付ける順序。定義の追加時にここへ足す。
local ORDER = { "container" }

---@param kind string
---@return docker.ResourceDefinition|nil
function M.get(kind)
  return definitions[kind]
end

---@return string[] `:Docker` のサブコマンド名一覧
function M.subcommands()
  local names = {}
  for _, kind in ipairs(ORDER) do
    table.insert(names, definitions[kind].subcommand)
  end
  return names
end

return M
