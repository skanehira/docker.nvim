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
---@field event_reload? boolean イベント時に 1 件ではなく全件を取り直す種別 (識別子がイベントの ID と対応しない場合)
---@field id fun(item: table): string    識別子の取り出し
---@field columns docker.ColumnDef[]
---@field status_column integer|nil      ハイライト対象のカラム位置 (1 始まり)
---@field status? fun(item: table): string|nil 状態カラムを持つ種別のみ
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

local IMAGE_FIELDS = {
  { key = "id", expr = ".ID" },
  { key = "repository", expr = ".Repository" },
  { key = "tag", expr = ".Tag" },
  { key = "created_since", expr = ".CreatedSince" },
  { key = "size", expr = ".Size" },
}

local VOLUME_FIELDS = {
  { key = "name", expr = ".Name" },
  { key = "driver", expr = ".Driver" },
  { key = "mountpoint", expr = ".Mountpoint" },
}

local NETWORK_FIELDS = {
  { key = "id", expr = ".ID" },
  { key = "name", expr = ".Name" },
  { key = "driver", expr = ".Driver" },
  { key = "scope", expr = ".Scope" },
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
  image = {
    kind = "image",
    subcommand = "images",
    view_type = "image_list",
    display_name = "Images",
    empty_text = "イメージがありません",
    -- `docker image ls` は `.Label` を扱えないため、ラベル由来のフィールドは持たない。
    -- コンテナと違いイメージの `.Size` は一覧の既定項目で、追加のコストが無い。
    list_args = function()
      return { "image", "ls", "--no-trunc", "--format", format.template(IMAGE_FIELDS) }
    end,
    -- イベントの Actor.ID はイメージの sha で、こちらの識別子 (タグ参照) と対応しない。
    -- 同じ sha に複数のタグが付くため 1 件だけの取り直しでは表せず、全件取り直す。
    -- イメージの一覧は件数が多くても数ミリ秒で描けるので実害が無い。
    event_reload = true,
    -- 同じイメージに複数のタグが付いていることがある。ID で消すとイメージ本体が
    -- 対象になり、他のタグで使われていると削除できない。タグがあればタグ参照で消す。
    delete_args = function(item)
      local repository = tostring(item.repository or "")
      local tag = tostring(item.tag or "")
      if repository ~= "" and repository ~= "<none>" and tag ~= "" and tag ~= "<none>" then
        return { "rmi", ("%s:%s"):format(repository, tag) }
      end
      return { "rmi", tostring(item.id) }
    end,
    -- 同じイメージに複数のタグが付くため、ID だと別々の行が 1 件に潰れる。
    -- 利用者が見て操作する単位 (タグ参照) を識別子にする。
    id = function(item)
      local repository = tostring(item.repository or "")
      local tag = tostring(item.tag or "")
      if repository ~= "" and repository ~= "<none>" and tag ~= "" and tag ~= "<none>" then
        return ("%s:%s"):format(repository, tag)
      end
      return tostring(item.id)
    end,
    columns = {
      { header = "REPOSITORY", value = plain("repository") },
      { header = "TAG", value = plain("tag") },
      { header = "SIZE", value = plain("size") },
      { header = "CREATED", value = plain("created_since") },
    },
    event_type = "image",
  },
  volume = {
    kind = "volume",
    subcommand = "volumes",
    view_type = "volume_list",
    display_name = "Volumes",
    empty_text = "ボリュームがありません",
    list_args = function()
      return { "volume", "ls", "--format", format.template(VOLUME_FIELDS) }
    end,
    item_args = function(id)
      return { "volume", "ls", "--filter", "name=" .. id, "--format", format.template(VOLUME_FIELDS) }
    end,
    delete_args = function(item)
      return { "volume", "rm", tostring(item.name) }
    end,
    -- ボリュームは名前が識別子。イベントでも Actor.ID に名前が入る。
    id = plain("name"),
    columns = {
      { header = "NAME", value = plain("name") },
      { header = "DRIVER", value = plain("driver") },
      { header = "MOUNTPOINT", value = plain("mountpoint") },
    },
    event_type = "volume",
  },
  network = {
    kind = "network",
    subcommand = "networks",
    view_type = "network_list",
    display_name = "Networks",
    empty_text = "ネットワークがありません",
    list_args = function()
      return { "network", "ls", "--no-trunc", "--format", format.template(NETWORK_FIELDS) }
    end,
    item_args = function(id)
      return { "network", "ls", "--no-trunc", "--filter", "id=" .. id, "--format", format.template(NETWORK_FIELDS) }
    end,
    -- 組み込みネットワーク (bridge / host / none) の削除は docker が拒否する。
    -- こちらで弾かず、docker のエラーをそのまま提示する (BR-016)。
    delete_args = function(item)
      return { "network", "rm", tostring(item.id) }
    end,
    id = plain("id"),
    columns = {
      { header = "NAME", value = plain("name") },
      { header = "DRIVER", value = plain("driver") },
      { header = "SCOPE", value = plain("scope") },
    },
    event_type = "network",
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
local ORDER = { "container", "image", "volume", "network", "service" }

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
