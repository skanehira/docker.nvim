--- Runs the docker compose CLI and resolves compose projects.
---
--- It has two roles.
---   `ls -a`: enumerates the projects that exist. It comes from labels, so it does not depend on the
---     working directory.
---   `config --format json`: for a single project, obtains its "project name" and
---     "all of its service names (including ones that have not been started)". Usable only where the
---     compose file can be read.
--- `config --services` is not used because its output order changes on every run.
local cli = require("docker.adapters.docker.cli")

local M = {}

---@class docker.ComposeProject
---@field name string
---@field working_dir string
---@field service_names string[]  Always in the same order (JSON key order is not guaranteed, so they are sorted)

---@class docker.ComposeProjectListing
---@field name string
---@field config_files string  Path of the compose file (comma-separated when there are several)

---@class docker.ComposeResult : docker.Result
---@field reason "outside"|"unavailable"|"invalid"|nil Category of the failure

local MESSAGE_UNAVAILABLE =
  "docker compose サブコマンドが使えません。compose プラグインの導入を確認してください。"

---@param haystack string
---@param needle string
---@return boolean
local function contains(haystack, needle)
  return haystack:lower():find(needle, 1, true) ~= nil
end

--- Splits a failing stderr into three. The exit code alone cannot tell them apart.
---
--- Note that the wording changes with the docker version (captured on a real machine):
---   compose missing: 29 says "unknown command", earlier versions "'compose' is not a docker command"
---   outside a project: "no configuration file provided: not found"
---   invalid file: yaml parse errors and the like (the content is not fixed)
---@param stderr string
---@return "outside"|"unavailable"|"invalid" reason
---@return string message
local function classify(stderr)
  if contains(stderr, "is not a docker command") or contains(stderr, "unknown command") then
    return "unavailable", MESSAGE_UNAVAILABLE
  end
  -- Being outside a project is handled as a normal case by the caller, so we return only the category.
  -- We do not give it dedicated guidance (the list can be opened from any directory, so telling the
  -- user to "reopen it where compose.yaml is" does not hold).
  if contains(stderr, "no configuration file provided") then
    return "outside", stderr
  end
  -- The content is not fixed, so we present docker's output as-is (BR-016).
  return "invalid", stderr
end

--- Enumerates the compose projects that exist.
--- `-a` is added so that stopped projects are included too. Because the listing is built from
--- container labels, it does not depend on the presence of a compose file or on the working directory.
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

--- Resolves a compose project.
--- Passing a project name names it explicitly with `-p`. The default name derived from the working
--- directory and the actual project name diverge with `COMPOSE_PROJECT_NAME` or a `-p` start, so we
--- name the project explicitly when looking up the definition of an existing project to prevent
--- picking the wrong one.
---@param cwd string Working directory in which to look for the compose file
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

--- Runs a compose subcommand.
---@param subcommand string[] e.g. { "-p", "shop", "up", "-d", "web" }
---@param cwd string|nil Passed only for operations that require a compose file
---@param on_done fun(result: docker.Result)
function M.run(subcommand, cwd, on_done)
  local args = { "compose" }
  vim.list_extend(args, subcommand)
  cli.run(args, on_done, { cwd = cwd })
end

return M
