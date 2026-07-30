--- docker compose CLI の実行と compose プロジェクトの解決。
---
--- 役割は 2 つある。
---   `ls -a`: 存在するプロジェクトの列挙。ラベル由来なので作業ディレクトリに依存しない。
---   `config --format json`: 1 つのプロジェクトについて「プロジェクト名」と
---     「サービス名の全件 (未起動を含む)」を得る。compose ファイルが読める場所でのみ使える。
--- `config --services` は出力順が実行のたびに変わるため使わない。
local cli = require("docker.adapters.docker.cli")

local M = {}

---@class docker.ComposeProject
---@field name string
---@field working_dir string
---@field service_names string[]  常に同じ順序 (JSON のキー順は保証されないため並べ替える)

---@class docker.ComposeProjectListing
---@field name string
---@field config_files string  compose ファイルのパス (複数ある場合はカンマ区切り)

---@class docker.ComposeResult : docker.Result
---@field reason "outside"|"unavailable"|"invalid"|nil 失敗の区分

local MESSAGE_OUTSIDE =
  "ここは docker compose プロジェクトではありません。compose.yaml のあるディレクトリで開いてください。"
local MESSAGE_UNAVAILABLE =
  "docker compose サブコマンドが使えません。compose プラグインの導入を確認してください。"

---@param haystack string
---@param needle string
---@return boolean
local function contains(haystack, needle)
  return haystack:lower():find(needle, 1, true) ~= nil
end

--- 失敗の stderr を 3 つに分ける。終了コードだけでは区別できない。
---
--- docker のバージョンで文言が変わる点に注意 (実機で採取):
---   compose 不在: 29 は "unknown command"、それ以前は "'compose' is not a docker command"
---   プロジェクト外: "no configuration file provided: not found"
---   ファイル不正: yaml のパースエラーなど (内容は一定でない)
---@param stderr string
---@return "outside"|"unavailable"|"invalid" reason
---@return string message
local function classify(stderr)
  if contains(stderr, "is not a docker command") or contains(stderr, "unknown command") then
    return "unavailable", MESSAGE_UNAVAILABLE
  end
  if contains(stderr, "no configuration file provided") then
    return "outside", MESSAGE_OUTSIDE
  end
  -- 内容が一定でないため、docker の出力をそのまま提示する (BR-016)。
  return "invalid", stderr
end

--- 存在する compose プロジェクトを列挙する。
--- `-a` を付けて停止中のプロジェクトも含める。コンテナのラベルから作られるため
--- compose ファイルの有無や作業ディレクトリに依存しない。
---@param on_done fun(result: docker.ComposeResult)
function M.list_projects(on_done)
  cli.run({ "compose", "ls", "-a", "--format", "json" }, function(result)
    if not result.ok then
      local reason, message = classify(tostring(result.error or ""))
      on_done({ ok = false, data = nil, error = message, code = result.code, reason = reason })
      return
    end

    if type(result.data) ~= "table" then
      on_done({
        ok = false,
        data = nil,
        error = "docker compose のプロジェクト一覧を解析できませんでした",
        code = result.code,
        reason = "invalid",
      })
      return
    end

    local projects = {}
    for _, entry in ipairs(result.data) do
      if type(entry) == "table" and type(entry.Name) == "string" and entry.Name ~= "" then
        table.insert(projects, {
          name = entry.Name,
          config_files = type(entry.ConfigFiles) == "string" and entry.ConfigFiles or "",
        })
      end
    end

    on_done({ ok = true, data = projects, error = nil, code = result.code })
  end, { parse = "json" })
end

--- compose プロジェクトを解決する。
--- プロジェクト名を渡すと `-p` で名指しする。作業ディレクトリから決まる既定の名前と
--- 実際のプロジェクト名は `COMPOSE_PROJECT_NAME` や `-p` 起動でずれるため、
--- 既存プロジェクトの定義を引くときは名指しして取り違えを防ぐ。
---@param cwd string compose ファイルを探す作業ディレクトリ
---@param on_done fun(result: docker.ComposeResult)
---@param opts { project_name: string|nil }|nil
function M.resolve_project(cwd, on_done, opts)
  local args = { "compose" }
  local project_name = opts and opts.project_name
  if project_name then
    vim.list_extend(args, { "-p", project_name })
  end
  vim.list_extend(args, { "config", "--format", "json" })

  cli.run(args, function(result)
    if not result.ok then
      local reason, message = classify(tostring(result.error or ""))
      on_done({ ok = false, data = nil, error = message, code = result.code, reason = reason })
      return
    end

    local project = result.data
    if type(project) ~= "table" or type(project.services) ~= "table" then
      on_done({
        ok = false,
        data = nil,
        error = "docker compose の設定を解析できませんでした",
        code = result.code,
        reason = "invalid",
      })
      return
    end

    local names = {}
    for name in pairs(project.services) do
      table.insert(names, name)
    end
    table.sort(names)

    on_done({
      ok = true,
      data = {
        name = project.name,
        working_dir = cwd,
        service_names = names,
      },
      error = nil,
      code = result.code,
    })
  end, { parse = "json", cwd = cwd })
end

--- compose のサブコマンドを実行する。
---@param subcommand string[] 例: { "-p", "shop", "up", "-d", "web" }
---@param cwd string|nil compose ファイルを必要とする操作でのみ渡す
---@param on_done fun(result: docker.Result)
function M.run(subcommand, cwd, on_done)
  local args = { "compose" }
  vim.list_extend(args, subcommand)
  cli.run(args, on_done, { cwd = cwd })
end

return M
