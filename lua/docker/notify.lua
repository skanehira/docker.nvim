--- Collects the notifications shown to the user in one place.
--- The notification kinds correspond to DESIGN_DETAIL_APP.md section 6.5.
local M = {}

local TITLE = "docker.nvim"

local debug_enabled = false

---@param msg string
---@param level integer
local function emit(msg, level)
  vim.notify(msg, level, { title = TITLE })
end

--- Switch debug output on or off (off by default).
---@param enabled boolean
function M.set_debug(enabled)
  debug_enabled = enabled and true or false
end

---@return boolean
function M.is_debug()
  return debug_enabled
end

--- Report the docker command that was run, its exit code, and the number of lines that
--- failed to parse. Only emitted when debug output is enabled.
---@param msg string
function M.debug(msg)
  if debug_enabled then
    emit(msg, vim.log.levels.DEBUG)
  end
end

--- Report that an operation succeeded.
---@param msg string
function M.info(msg)
  emit(msg, vim.log.levels.INFO)
end

--- Report an operation whose preconditions are not met, or a duplicate request.
---@param msg string
function M.warn(msg)
  emit(msg, vim.log.levels.WARN)
end

--- Report a failed operation or an environment problem.
---@param msg string
function M.error(msg)
  emit(msg, vim.log.levels.ERROR)
end

return M
