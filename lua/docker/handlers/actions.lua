--- Dispatches action names to their actual handling.
---
--- Proceeds in this order: precondition state check (BR-007) -> duplicate request rejection (BR-009)
--- -> docker execution. Internal state is never changed even on failure. The list is updated via docker events.
local cli = require("docker.adapters.docker.cli")
local file_edit = require("docker.handlers.file_edit")
local compose = require("docker.adapters.docker.compose")
local notify = require("docker.notify")
local operations = require("docker.handlers.operations")
local ports = require("docker.resources.ports")
local terminal = require("docker.handlers.terminal")

local M = {}

---@class docker.ActionContext
---@field def docker.ResourceDefinition
---@field item table|nil

--- Container operations that change state.
--- When called in a state that does not satisfy `requires`, warns without invoking docker.
local CONTAINER_ACTIONS = {
  start = {
    args = "start",
    forbids = { running = true, restarting = true },
    denied = "%s is already running",
    success = "Started %s",
  },
  stop = {
    args = "stop",
    requires = { running = true, restarting = true },
    denied = "%s is not running, so it cannot be stopped",
    success = "Stopped %s",
  },
  restart = {
    args = "restart",
    success = "Restarted %s",
  },
  pause = {
    args = "pause",
    requires = { running = true },
    denied = "%s is not running, so it cannot be paused",
    success = "Paused %s",
  },
  unpause = {
    args = "unpause",
    requires = { paused = true },
    denied = "%s is not paused",
    success = "Unpaused %s",
  },
  kill = {
    args = "kill",
    requires = { running = true, restarting = true },
    denied = "%s is not running, so it cannot be killed",
    success = "Killed %s",
  },
}

---@param item table
---@return string
local function label_of(item)
  local name = item.name
  if type(name) == "string" and name ~= "" then
    return name
  end
  return tostring(item.id)
end

---@param spec table
---@param state string
---@return boolean allowed
local function allowed(spec, state)
  if spec.requires and not spec.requires[state] then
    return false
  end
  if spec.forbids and spec.forbids[state] then
    return false
  end
  return true
end

--- Marks the operation as running, invokes docker, and clears the mark on completion.
---@param target_id string
---@param label string
---@param operation string
---@param args string[]
---@param success string message on success (`%s` is filled with the target name)
local function run_exclusive(target_id, label, operation, args, success)
  if not operations.begin(target_id, operation) then
    notify.warn(("%s: the %s operation is already in progress"):format(label, operation))
    return
  end

  cli.run(args, function(result)
    operations.finish(target_id, operation)
    if result.ok then
      notify.info(success:format(label))
    else
      -- Present docker's standard error output as-is (BR-016).
      notify.error(result.error or "Failed to run docker")
    end
  end)
end

--- Deletes after confirmation. Requests the deletion from docker only when the answer is `y`.
---@param ctx docker.ActionContext
---@param item table
---@param label string
local function delete(ctx, item, label)
  vim.ui.input({ prompt = ("Delete %s? (y/N): "):format(label) }, function(answer)
    if answer ~= "y" and answer ~= "Y" then
      return
    end
    run_exclusive(tostring(item.id), label, "delete", ctx.def.delete_args(item), "Deleted %s")
  end)
end

--- Per-service compose operations. All of them run detached (BR-023).
--- `needs_config` marks operations that cannot run without reading the compose file. Stopping and
--- tearing down only need the project name, but starting up needs the definition itself.
local SERVICE_ACTIONS = {
  up = { args = { "up", "-d" }, success = "Started %s", needs_config = true },
  stop = { args = { "stop" }, success = "Stopped %s" },
  restart = { args = { "restart" }, success = "Restarted %s" },
}

--- Per-project compose operations.
local PROJECT_ACTIONS = {
  project_up = { args = { "up", "-d" }, success = "Started %s", needs_config = true },
  project_down = {
    args = { "down" },
    confirm = "Remove %s? (y/N): ",
    success = "Removed %s",
  },
}

--- Marks the operation as running, invokes compose, and clears the mark on completion.
---@param target_id string
---@param label string
---@param operation string
---@param args string[]
---@param cwd string
---@param success string
local function run_compose_exclusive(target_id, label, operation, args, cwd, success)
  if not operations.begin(target_id, operation) then
    notify.warn(("%s: the %s operation is already in progress"):format(label, operation))
    return
  end

  compose.run(args, cwd, function(result)
    operations.finish(target_id, operation)
    if result.ok then
      notify.info(success:format(label))
    else
      notify.error(result.error or "Failed to run docker compose")
    end
  end)
end

--- Operations that open a terminal. A container that is not running cannot be entered.
local TERMINAL_ACTIONS = {
  -- Logs can be read even while stopped, so no precondition is imposed.
  logs = { requires = nil },
  shell = { requires = { running = true }, denied = "%s is not running, so a shell cannot be opened" },
  exec = {
    requires = { running = true },
    denied = "%s is not running, so a command cannot be run",
  },
}

---@param name string
---@param item table
---@param label string
local function open_terminal(name, item, label)
  local id = tostring(item.id)
  if name == "logs" then
    terminal.open_logs(id, label)
    return
  end
  if name == "shell" then
    terminal.open_shell(id, label)
    return
  end
  vim.ui.input({ prompt = ("Command to run in %s: "):format(label) }, function(command)
    if type(command) ~= "string" or vim.trim(command) == "" then
      return
    end
    terminal.open_exec(id, label, command)
  end)
end

--- The target to launch as a throwaway container. Uses the tag when one is present.
---@param item table
---@return string
local function image_ref(item)
  local repository = tostring(item.repository or "")
  local tag = tostring(item.tag or "")
  if repository ~= "" and repository ~= "<none>" and tag ~= "" and tag ~= "<none>" then
    return ("%s:%s"):format(repository, tag)
  end
  return tostring(item.id)
end

--- Opens a published port in the browser. Lets the user choose when there is more than one.
---@param item table
---@param label string
local function open_browser(item, label)
  local urls = ports.published(item.ports)
  if #urls == 0 then
    notify.warn(("%s has no published ports"):format(label))
    return
  end
  if #urls == 1 then
    vim.ui.open(urls[1])
    return
  end
  vim.ui.select(urls, { prompt = ("Which port of %s do you want to open?"):format(label) }, function(choice)
    if choice then
      vim.ui.open(choice)
    end
  end)
end

--- Asks for the two paths and then runs `docker cp`.
---@param item table
---@param label string
---@param direction "to"|"from"
local function copy_file(item, label, direction)
  local id = tostring(item.id)
  local first = direction == "to" and "Source (host): " or ("Source (in %s): "):format(label)
  local second = direction == "to" and ("Destination (in %s): "):format(label) or "Destination (host): "

  vim.ui.input({ prompt = first }, function(source)
    if type(source) ~= "string" or vim.trim(source) == "" then
      return
    end
    vim.ui.input({ prompt = second }, function(destination)
      if type(destination) ~= "string" or vim.trim(destination) == "" then
        return
      end
      local from = direction == "to" and source or ("%s:%s"):format(id, source)
      local to = direction == "to" and ("%s:%s"):format(id, destination) or destination
      run_exclusive(id, label, "copy", { "cp", from, to }, "Copied %s")
    end)
  end)
end

--- Executes an action.
---@param name string
---@param ctx docker.ActionContext
function M.execute(name, ctx)
  local spec = CONTAINER_ACTIONS[name]
  local terminal_spec = TERMINAL_ACTIONS[name]
  local EXTRA = { quickrun = true, open_browser = true, copy_to = true, copy_from = true, edit_file = true }
  if ctx.def.kind ~= "service" and not spec and not terminal_spec and not EXTRA[name] and name ~= "delete" then
    notify.warn(("Unsupported operation: %s"):format(tostring(name)))
    return
  end

  local item = ctx.item
  if not item then
    notify.warn("No target for the operation")
    return
  end

  local label = label_of(item)

  -- Operations on the compose service list are dispatched to docker compose.
  -- The list merges all projects, so the target is the project of that row.
  -- Naming the project explicitly lets the operation run without depending on the working directory.
  if ctx.def.kind == "service" then
    local project_name = tostring(item.project)
    local working_dir = tostring(item.working_dir or "")

    --- Operations that need the compose file are not issued when its location is unknown.
    ---@param compose_spec table
    ---@param target_id string
    ---@param target_label string
    ---@param args string[]
    local function dispatch(compose_spec, target_id, target_label, args)
      if compose_spec.needs_config and working_dir == "" then
        notify.warn(("%s cannot be started because the location of its compose file is unknown"):format(target_label))
        return
      end
      local cwd = compose_spec.needs_config and working_dir or nil
      run_compose_exclusive(target_id, target_label, name, args, cwd, compose_spec.success)
    end

    ---@param compose_spec table
    ---@return string[]
    local function compose_args(compose_spec)
      local args = { "-p", project_name }
      vim.list_extend(args, compose_spec.args)
      return args
    end

    local project_spec = PROJECT_ACTIONS[name]
    if project_spec then
      local args = compose_args(project_spec)
      if project_spec.confirm then
        vim.ui.input({ prompt = project_spec.confirm:format(project_name) }, function(answer)
          if answer ~= "y" and answer ~= "Y" then
            return
          end
          dispatch(project_spec, project_name, project_name, args)
        end)
        return
      end
      dispatch(project_spec, project_name, project_name, args)
      return
    end

    local service_spec = SERVICE_ACTIONS[name]
    if service_spec then
      local args = compose_args(service_spec)
      table.insert(args, tostring(item.name))
      dispatch(service_spec, ("%s/%s"):format(project_name, item.name), label, args)
      return
    end

    if name == "logs" then
      -- A service without a container has no logs. Warn instead of opening a terminal.
      if tostring(item.container_id or "") == "" then
        notify.warn(("%s has no container, so its logs cannot be shown"):format(label))
        return
      end
      terminal.open_compose_logs(project_name, tostring(item.name), label)
      return
    end

    notify.warn(("Unsupported operation: %s"):format(tostring(name)))
    return
  end

  if name == "delete" then
    delete(ctx, item, label)
    return
  end

  if name == "quickrun" then
    terminal.open_quickrun(image_ref(item), label)
    return
  end

  if name == "open_browser" then
    open_browser(item, label)
    return
  end

  if name == "edit_file" then
    vim.ui.input({ prompt = ("File to edit in %s: "):format(label) }, function(path)
      if type(path) ~= "string" or vim.trim(path) == "" then
        return
      end
      file_edit.open(tostring(item.id), label, vim.trim(path))
    end)
    return
  end

  if name == "copy_to" or name == "copy_from" then
    copy_file(item, label, name == "copy_to" and "to" or "from")
    return
  end

  if terminal_spec then
    local state = ctx.def.status and ctx.def.status(item) or ""
    if terminal_spec.requires and not terminal_spec.requires[state] then
      notify.warn(terminal_spec.denied:format(label))
      return
    end
    open_terminal(name, item, label)
    return
  end
  local state = ctx.def.status and ctx.def.status(item) or ""
  if not allowed(spec, state) then
    notify.warn(spec.denied:format(label))
    return
  end

  local target_id = tostring(item.id)
  run_exclusive(target_id, label, name, { spec.args, target_id }, spec.success)
end

return M
