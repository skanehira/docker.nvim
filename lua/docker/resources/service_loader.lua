--- compose サービス一覧の取得。
---
--- サービス一覧は docker の単一コマンドで取れないため、複数の取得結果を突き合わせて
--- 組み立てる (7.3)。多段の非同期を含むので、宣言的定義である registry から分けてここに置く。
--- コンテナ一覧の引数は registry から `container_args` で受け取る
--- (registry を require し返すと循環参照になる)。
---
--- compose ファイルがある場所でしか一覧を出せないと、プロジェクトの外からは何も見えない。
--- プロジェクトの所在はコンテナのラベルから逆算できるので、次の 3 つを組み合わせる。
---   `compose ls -a`: 存在するプロジェクトの列挙 (停止中を含む)
---   コンテナ一覧    : サービスの実体と、compose ファイルのある場所 (working_dir ラベル)
---   `compose config`: サービスの定義全件。起動していないサービスはここでしか分からない
local cli = require("docker.adapters.docker.cli")
local compose = require("docker.adapters.docker.compose")
local services = require("docker.resources.services")

local M = {}

---@class docker.ServiceLoadContext
---@field cwd string              ビューを開いた時点の作業ディレクトリ
---@field container_args string[] コンテナ一覧を取る docker 引数

---@class docker.ServiceLoadResult : docker.Result
---@field warning string|nil 一覧は出せるが利用者に伝えることがある場合の文言

--- コンテナのラベルから、そのプロジェクトの compose ファイルがある場所を拾う。
---@param project_name string
---@param containers table[]
---@return string 分からなければ空文字列
local function working_dir_from_containers(project_name, containers)
  for _, item in ipairs(containers) do
    if item.compose_project == project_name then
      local dir = item.compose_working_dir
      if type(dir) == "string" and dir ~= "" then
        return dir
      end
    end
  end
  return ""
end

--- 設定ファイルのパスから場所を割り出す。working_dir ラベルが無い場合の受け皿。
--- 複数ある場合はカンマ区切りで並ぶので、先頭 (基底となる compose ファイル) を使う。
---@param config_files string
---@return string 分からなければ空文字列
local function working_dir_from_config_files(config_files)
  local first = vim.split(config_files, ",", { plain = true })[1]
  if type(first) ~= "string" or first == "" then
    return ""
  end
  return vim.fs.dirname(first)
end

--- 列挙されたプロジェクトと作業ディレクトリのプロジェクトを 1 つの集合にする。
--- 作業ディレクトリ側はサービスの定義まで分かっているので、同名なら優先する。
---@param listings docker.ComposeProjectListing[]
---@param cwd_project docker.ComposeProject|nil
---@param containers table[]
---@return docker.ComposeProject[] service_names が nil のものは定義が未解決
local function collect_projects(listings, cwd_project, containers)
  local projects, index = {}, {}

  for _, listing in ipairs(listings) do
    local working_dir = working_dir_from_containers(listing.name, containers)
    if working_dir == "" then
      working_dir = working_dir_from_config_files(listing.config_files)
    end
    local project = { name = listing.name, working_dir = working_dir, service_names = nil }
    index[listing.name] = project
    table.insert(projects, project)
  end

  if cwd_project then
    local existing = index[cwd_project.name]
    if existing then
      existing.working_dir = cwd_project.working_dir
      existing.service_names = cwd_project.service_names
    else
      table.insert(projects, cwd_project)
    end
  end

  return projects
end

--- 定義が未解決のプロジェクトについて `compose config` を並列に引く。
--- 引けなかったプロジェクトはコンテナのラベルから逆算する (起動中のサービスのみ)。
---@param projects docker.ComposeProject[]
---@param containers table[]
---@param on_done fun()
local function resolve_pending(projects, containers, on_done)
  local pending = {}
  for _, project in ipairs(projects) do
    if project.service_names == nil then
      if project.working_dir == "" then
        project.service_names = services.derive_service_names(project.name, containers)
      else
        table.insert(pending, project)
      end
    end
  end

  -- 1 件も引く必要が無いときにここを抜けないと、完了が呼ばれないまま止まる。
  if #pending == 0 then
    on_done()
    return
  end

  local remaining = #pending
  for _, project in ipairs(pending) do
    compose.resolve_project(project.working_dir, function(resolved)
      if resolved.ok then
        project.service_names = resolved.data.service_names
      else
        -- compose ファイルが消えている場合も含め、引けない理由は問わない。
        -- 一覧そのものは出せるので、実体のあるサービスだけで代替する。
        project.service_names = services.derive_service_names(project.name, containers)
      end
      remaining = remaining - 1
      if remaining == 0 then
        on_done()
      end
    end, { project_name = project.name })
  end
end

--- サービス一覧を取得する。
---@param ctx docker.ServiceLoadContext
---@param on_done fun(result: docker.ServiceLoadResult)
function M.load(ctx, on_done)
  local listed, containers, cwd_resolved

  local function finish()
    if not listed.ok then
      on_done(listed)
      return
    end
    if not containers.ok then
      on_done(containers)
      return
    end

    -- プロジェクト外での実行は珍しくないので失敗として扱わない。
    -- compose ファイルが壊れている場合だけ、一覧を出したうえで理由を伝える。
    local cwd_project = cwd_resolved.ok and cwd_resolved.data or nil
    local warning = nil
    if not cwd_resolved.ok and cwd_resolved.reason == "invalid" then
      warning = cwd_resolved.error
    end

    local projects = collect_projects(listed.data, cwd_project, containers.data)
    resolve_pending(projects, containers.data, function()
      on_done({
        ok = true,
        data = services.assemble_all(projects, containers.data),
        error = nil,
        code = 0,
        warning = warning,
      })
    end)
  end

  local remaining = 3
  local function arrived()
    remaining = remaining - 1
    if remaining == 0 then
      finish()
    end
  end

  compose.list_projects(function(result)
    listed = result
    arrived()
  end)

  cli.run(ctx.container_args, function(result)
    containers = result
    arrived()
  end, { parse = "ndjson" })

  compose.resolve_project(ctx.cwd, function(result)
    cwd_resolved = result
    arrived()
  end)
end

return M
