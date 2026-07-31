--- Deciding which Neovim versions are supported.
---
--- 0.10 or later is required because `vim.system` is used. In environments that do not
--- meet the requirement neither the command nor the keymaps are registered, so no later
--- operation raises a runtime error.
--- This module depends on no other module, because it has to be loaded at startup.
local M = {}

M.MINIMUM = { major = 0, minor = 10 }

---@param v table|nil Defaults to the running Neovim when omitted
---@return table
local function resolve(v)
  return v or vim.version()
end

--- Whether the required version is met.
---@param v table|nil
---@return boolean
function M.supported(v)
  local current = resolve(v)
  if current.major ~= M.MINIMUM.major then
    return current.major > M.MINIMUM.major
  end
  return current.minor >= M.MINIMUM.minor
end

--- The message notified when the requirement is not met.
---@param v table|nil
---@return string
function M.requirement_message(v)
  local current = resolve(v)
  return ("docker.nvim requires Neovim %d.%d or later (current: %d.%d.%d)"):format(
    M.MINIMUM.major,
    M.MINIMUM.minor,
    current.major,
    current.minor,
    current.patch or 0
  )
end

return M
