--- Fetching of the compose service list.
---
--- The service list cannot be obtained by a single docker command, so it is assembled by matching
--- the results of several fetches (section 7.3). It involves multi-stage asynchrony, so it is kept
--- here separately from registry, which holds the declarative definitions.
--- The arguments for the container list are received from registry through `container_args`
--- (requiring registry back would create a circular reference).
---
--- If the list could only be shown where a compose file exists, nothing would be visible from
--- outside a project. The location of a project can be derived from the container labels, so the
--- following three are combined.
---   `compose ls -a`: enumeration of the existing projects (including stopped ones)
---   container list : the service instances, and the location of the compose file (working_dir label)
---   `compose config`: all of the service definitions. Services that are not started are only known here
local cli = require("docker.adapters.docker.cli")
local compose = require("docker.adapters.docker.compose")
local services = require("docker.resources.services")

local M = {}

---@class docker.ServiceLoadContext
---@field cwd string              the working directory at the moment the view was opened
---@field container_args string[] the docker arguments that fetch the container list

---@class docker.ServiceLoadResult : docker.Result
---@field warning string|nil wording for cases where the list can be shown but there is something to tell the user

--- Picks up the location of the compose file of that project from the container labels.
---@param project_name string
---@param containers table[]
---@return string an empty string if it is unknown
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

--- Works out the location from the paths of the config files. The fallback for when there is no
--- working_dir label. When there are several they are listed comma-separated, so the first one
--- (the base compose file) is used.
---@param config_files string
---@return string an empty string if it is unknown
local function working_dir_from_config_files(config_files)
  local first = vim.split(config_files, ",", { plain = true })[1]
  if type(first) ~= "string" or first == "" then
    return ""
  end
  return vim.fs.dirname(first)
end

--- Puts the enumerated projects and the project of the working directory into a single set.
--- The working directory side knows the service definitions too, so it wins on the same name.
---@param listings docker.ComposeProjectListing[]
---@param cwd_project docker.ComposeProject|nil
---@param containers table[]
---@return docker.ComposeProject[] the ones whose service_names is nil have unresolved definitions
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

--- Runs `compose config` in parallel for the projects whose definitions are unresolved.
--- For projects it could not look up, the names are derived from the container labels (running
--- services only).
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

  -- Without leaving here when there is nothing to look up, completion is never called and it stalls.
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
        -- The reason it cannot be looked up does not matter, including the compose file being gone.
        -- The list itself can be shown, so the services that have an instance stand in for it.
        project.service_names = services.derive_service_names(project.name, containers)
      end
      remaining = remaining - 1
      if remaining == 0 then
        on_done()
      end
    end, { project_name = project.name })
  end
end

--- Fetches the service list.
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

    -- Running outside a project is not unusual, so it is not treated as a failure.
    -- Only when the compose file is broken, the list is shown along with the reason.
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
