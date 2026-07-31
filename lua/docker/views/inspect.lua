--- Inspect view. Shows the result of `docker inspect` as JSON.
---
--- It is only stacked above the list with `zindex`; the list below is left untouched.
--- Closing it keeps the content and the cursor position of the list as they were (BR-018).
local cli = require("docker.adapters.docker.cli")
local notify = require("docker.notify")
local window = require("docker.ui.window")

local M = {}

--- The inspect view is placed in front of the list but behind the help.
local ZINDEX = 150

--- The output of `docker inspect` is already formatted, so it is split into lines and shown as is.
--- Re-parsing and re-formatting it would require an external formatter and would break the key order.
---@param stdout string
---@return string[]
local function to_lines(stdout)
  return vim.split(stdout, "\n", { plain = true, trimempty = true })
end

--- Open the inspect view. The view is not opened when fetching fails.
---@param def docker.ResourceDefinition
---@param item table
---@param on_done fun(handle: docker.Window|nil)|nil
function M.open(def, item, on_done)
  local function done(handle)
    if on_done then
      on_done(handle)
    end
  end

  local id = tostring(def.id(item))
  -- The output is shown as is, but the view is only opened after checking that it parses
  -- (docker may write errors to stdout).
  cli.run({ "inspect", id }, function(result)
    if not result.ok then
      notify.error(result.error or "Could not fetch the details")
      return done(nil)
    end

    local raw = type(result.data) == "string" and result.data or ""
    if not pcall(vim.json.decode, raw) then
      notify.error("Could not parse the details output")
      return done(nil)
    end

    local label = item.name
    if type(label) ~= "string" or label == "" then
      label = id
    end

    local handle = window.open({
      title = ("Inspect (%s)"):format(label),
      zindex = ZINDEX,
    })
    window.set_lines(handle, to_lines(raw))
    vim.bo[handle.bufnr].filetype = "json"

    -- Closing with `q` leaves the list below as it was.
    vim.keymap.set("n", "q", function()
      window.close(handle)
    end, { buffer = handle.bufnr, nowait = true, silent = true, desc = "docker.nvim: close the details" })

    done(handle)
  end)
end

return M
