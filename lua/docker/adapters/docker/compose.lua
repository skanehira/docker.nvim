--- docker compose CLI の実行と compose プロジェクトの解決。
---
--- `config --format json` を 1 回実行して「プロジェクト内かの判定」「プロジェクト名」
--- 「サービス名の全件 (未起動を含む)」の 3 つを得る。
--- `config --services` は出力順が実行のたびに変わるため使わない。
local cli = require("docker.adapters.docker.cli")

local M = {}

---@class docker.ComposeProject
---@field name string
---@field working_dir string
---@field service_names string[]  常に同じ順序 (JSON のキー順は保証されないため並べ替える)

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

--- compose プロジェクトを解決する。
---@param cwd string ビューを開いた時点の作業ディレクトリ (BR-003)
---@param on_done fun(result: docker.ComposeResult)
function M.resolve_project(cwd, on_done)
  cli.run({ "compose", "config", "--format", "json" }, function(result)
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
---@param subcommand string[] 例: { "up", "-d", "web" }
---@param cwd string
---@param on_done fun(result: docker.Result)
function M.run(subcommand, cwd, on_done)
  local args = { "compose" }
  vim.list_extend(args, subcommand)
  cli.run(args, on_done, { cwd = cwd })
end

return M
