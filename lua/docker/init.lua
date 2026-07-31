--- Public API. Taking in the settings, and opening and closing the views.
local config = require("docker.config")
local lifecycle = require("docker.handlers.lifecycle")
local notify = require("docker.notify")
local registry = require("docker.resources.registry")
local version = require("docker.version")

local M = {}

--- The plugin is disabled in environments that do not meet the required version.
--- It is stopped at the entry point so that no later operation raises a runtime error.
local disabled = false

--- Take in the user's settings.
--- If Neovim is below the required version, notify a message and disable the plugin.
---@param opts docker.Config|nil
function M.setup(opts)
  if not version.supported() then
    disabled = true
    notify.error(version.requirement_message())
    return
  end

  disabled = false
  config.setup(opts)
end

--- Open a list view.
---@param kind string One of "containers" | "images" | "volumes" | "networks" | "services", or the singular kind
function M.open(kind)
  if disabled then
    return
  end

  local def = registry.get(kind) or registry.by_subcommand(kind)
  if not def then
    notify.warn(("使い方: :Docker {%s}"):format(table.concat(registry.subcommands(), "|")))
    return
  end

  lifecycle.open(def.kind)
end

--- Close the open views.
function M.close()
  lifecycle.close_all()
end

--- For tests. Resets the disabled state.
function M._reset()
  disabled = false
end

return M
