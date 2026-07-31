--- Helpers that pull the values used for display out of the raw list data.
---
--- Deciding whether an item came from compose is concentrated here. Labels are collected by
--- naming the key through `.Label`, so even if a fake label is planted in a value it stays an
--- empty string.
local M = {}

--- The value attached to the one-off containers `docker compose run` creates.
local ONEOFF_TRUE = "True"

---@param item table
---@param key string
---@return string
local function str(item, key)
  local value = item[key]
  return type(value) == "string" and value or ""
end

--- Whether the container was created by compose.
--- The condition is that both the project name and the service name are present
--- (DESIGN_DETAIL_APP.md section 4.1).
---@param item table
---@return boolean
function M.is_compose(item)
  return str(item, "compose_project") ~= "" and str(item, "compose_service") ~= ""
end

--- Whether it is a one-off container created by `docker compose run` (BR-006).
---@param item table
---@return boolean
function M.is_oneoff(item)
  return str(item, "compose_oneoff") == ONEOFF_TRUE
end

--- If the container is the running instance of a service, return which service it belongs to.
--- One-off containers are not tied to a service (BR-006).
---@param item table
---@return { project: string, service: string }|nil
function M.service_of(item)
  if not M.is_compose(item) or M.is_oneoff(item) then
    return nil
  end
  return { project = str(item, "compose_project"), service = str(item, "compose_service") }
end

--- The display string for the published ports.
---@param item table
---@return string
function M.ports(item)
  return str(item, "ports")
end

--- The state (running / exited / paused and so on).
---@param item table
---@return string
function M.state(item)
  return str(item, "state")
end

return M
