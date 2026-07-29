--- リソース種別の宣言的定義。
---
--- 種別の追加はこのファイルへの定義追加だけで完結させ、ビューとハンドラに
--- 種別ごとの分岐を増やさない (レジストリパターン)。
local cli = require("docker.adapters.docker.cli")
local compose = require("docker.adapters.docker.compose")
local fields = require("docker.resources.fields")
local format = require("docker.format")
local services = require("docker.resources.services")

local M = {}

---@class docker.ColumnDef
---@field header string
---@field value fun(item: table): string

---@class docker.ResourceDefinition
---@field kind string                    "container" | "image" | "volume" | "network" | "service"
---@field subcommand string              `:Docker` に渡す引数 (例: "containers")
---@field view_type string               キーマップを引くビュー種別 (例: "container_list")
---@field display_name string
---@field empty_text string              0 件のときに一覧へ出す 1 行
---@field list_args? fun(): string[]     一覧取得の docker 引数 (load を持つ種別では省略)
---@field delete_args? fun(item: table): string[] 削除の docker 引数 (強制削除は付けない)
---@field item_args? fun(id: string): string[]    1 件だけ取り直す docker 引数
---@field load? fun(ctx: table, on_done: fun(result: table)) 一覧の取得が docker の単一コマンドで表せない種別用
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

-- 先に宣言しておく。サービスの `load` がコンテナ定義を参照するため、
-- テーブル構築中に `definitions` がローカルとして見えている必要がある。
---@type table<string, docker.ResourceDefinition>
local definitions
definitions = {
  container = {
    kind = "container",
    subcommand = "containers",
    view_type = "container_list",
    display_name = "Containers",
    empty_text = "コンテナがありません",
    -- `-a` は停止中のコンテナも一覧に含めるため (BR-022)。
    -- `--no-trunc` が無いと ID が 12 文字、Command が 20 文字で切り詰められる。
    list_args = function()
      return { "ps", "-a", "--no-trunc", "--format", format.template(CONTAINER_FIELDS) }
    end,
    -- イベントで変化した 1 件だけを取り直す。全件取得より軽い。
    item_args = function(id)
      return { "ps", "-a", "--no-trunc", "--filter", "id=" .. id, "--format", format.template(CONTAINER_FIELDS) }
    end,
    -- 強制削除 (-f) は付けない。実行中コンテナの削除は docker に拒否させる (BR-002)。
    delete_args = function(item)
      return { "rm", tostring(item.id) }
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
  service = {
    kind = "service",
    subcommand = "services",
    view_type = "service_list",
    display_name = "Services",
    empty_text = "サービスが定義されていません",
    -- サービス一覧は docker の単一コマンドで取れない。compose の定義と
    -- コンテナ一覧を突き合わせて組み立てる (7.3)。
    load = function(ctx, on_done)
      compose.resolve_project(ctx.cwd, function(resolved)
        if not resolved.ok then
          on_done(resolved)
          return
        end
        cli.run(definitions.container.list_args(), function(containers)
          if not containers.ok then
            on_done(containers)
            return
          end
          on_done({
            ok = true,
            data = services.assemble(resolved.data, containers.data),
            error = nil,
            code = 0,
            project = resolved.data,
          })
        end, { parse = "ndjson" })
      end)
    end,
    id = function(item)
      return ("%s/%s"):format(tostring(item.project), tostring(item.name))
    end,
    columns = {
      { header = "SERVICE", value = plain("name") },
      { header = "STATUS", value = plain("status") },
      { header = "CONTAINER", value = plain("container") },
    },
    status_column = 2,
    status = plain("status"),
    -- サービスの状態はコンテナの状態から決まるので、コンテナのイベントで更新する。
    event_type = "container",
  },
}

--- `:Docker` のサブコマンドとして受け付ける順序。定義の追加時にここへ足す。
local ORDER = { "container", "service" }

---@param kind string
---@return docker.ResourceDefinition|nil
function M.get(kind)
  return definitions[kind]
end

--- `:Docker` の引数から定義を引く。
---@param subcommand string
---@return docker.ResourceDefinition|nil
function M.by_subcommand(subcommand)
  for _, kind in ipairs(ORDER) do
    if definitions[kind].subcommand == subcommand then
      return definitions[kind]
    end
  end
  return nil
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
