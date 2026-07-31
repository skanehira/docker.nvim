--- Assembly of the compose service list.
---
--- The display is built from the container instances, but services that are defined in
--- compose.yaml and not started are listed too (BR-005). The matching is done with the container
--- labels, and one-off containers created by `docker compose run` are not treated as the instance
--- of a service (BR-006).
local fields = require("docker.resources.fields")

local M = {}

---@class docker.Service
---@field project string
---@field name string
---@field container string      the name of the container it is tied to (empty string if there is none)
---@field container_id string   the ID of the container it is tied to (empty string if there is none)
---@field status string         the state of the container. "none" if there is no container tied to it
---@field working_dir string    the location of the compose file (empty string if it is unknown)

--- The state of a service that has not been started.
local NONE = "none"

--- Assembles the service list from the compose definitions and the container list.
--- The order is kept exactly as the service_names passed by the caller (ascending by service name).
---@param project docker.ComposeProject
---@param containers table[]
---@return docker.Service[]
function M.assemble(project, containers)
  --- service name -> the container tied to it
  local by_service = {}
  for _, item in ipairs(containers) do
    local owner = fields.service_of(item)
    if owner and owner.project == project.name then
      local current = by_service[owner.service]
      -- When one service has several containers (scale), a running one represents it.
      -- Always taking the first one can make a service look stopped while a replica is running.
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
      working_dir = project.working_dir,
    })
  end
  return items
end

--- Derives the service names from the container labels.
--- For a project whose compose file cannot be read the definitions cannot be looked up, so only
--- the services that have an instance are listed. Services that are defined but not started
--- (BR-005) cannot be known through this path.
---@param project_name string
---@param containers table[]
---@return string[] always in the same order
function M.derive_service_names(project_name, containers)
  local seen, names = {}, {}
  for _, item in ipairs(containers) do
    local owner = fields.service_of(item)
    if owner and owner.project == project_name and not seen[owner.service] then
      seen[owner.service] = true
      table.insert(names, owner.service)
    end
  end
  table.sort(names)
  return names
end

--- Merges the services of several projects into a single list.
--- The order in which the projects are obtained can change from run to run, so they are sorted by
--- name to keep the row order stable.
---@param projects docker.ComposeProject[]
---@param containers table[]
---@return docker.Service[]
function M.assemble_all(projects, containers)
  local ordered = vim.deepcopy(projects)
  table.sort(ordered, function(a, b)
    return a.name < b.name
  end)

  local items = {}
  for _, project in ipairs(ordered) do
    vim.list_extend(items, M.assemble(project, containers))
  end
  return items
end

return M
