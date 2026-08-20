--- Default settings, keymap definitions and merging with the user's settings.
---
--- Keys are held per view type, so that the same key can be bound to a different action
--- per view type (BR-015).
local notify = require("docker.notify")

local M = {}

---@class docker.Config
---@field keymaps table<string, table<string, string>>  view type -> action name -> key
---@field debug boolean
---@field column_max_widths table<string, table<string, integer>> view type -> column name -> display width

--- The default keymaps. They follow the bindings of denops-docker.vim.
--- `common` applies to every list view.
local DEFAULT_KEYMAPS = {
  common = {
    inspect = "<CR>",
    refresh = "R",
    switch_view = "<Tab>",
    help = "?",
    close = "q",
    filter = "<C-f>",
  },
  container_list = {
    start = "u",
    stop = "d",
    restart = "r",
    kill = "<C-k>",
    pause = "p",
    unpause = "P",
    shell = "a",
    exec = "e",
    logs = "t",
    delete = "D",
    copy_to = "ct",
    copy_from = "cf",
    edit_file = "E",
    open_browser = "<C-o>",
    drilldown = "gd",
  },
  image_list = {
    quickrun = "r",
    delete = "D",
    drilldown = "gd",
  },
  volume_list = {
    delete = "D",
  },
  network_list = {
    delete = "D",
  },
  service_list = {
    up = "u",
    stop = "d",
    restart = "r",
    logs = "t",
    project_up = "U",
    project_down = "D",
    drilldown = "gd",
  },
}

--- The upper bound on the display width of a column, per view type.
--- Only the columns listed here can be configured; a column with no entry is never cut.
--- An image name is long enough to push the columns after it off the screen, so it is the
--- only one that is limited by default.
local DEFAULT_COLUMN_MAX_WIDTHS = {
  container_list = {
    image = 30,
  },
}

---@type docker.Config|nil
local current = nil

---@return docker.Config
local function defaults()
  return {
    keymaps = vim.deepcopy(DEFAULT_KEYMAPS),
    debug = false,
    column_max_widths = vim.deepcopy(DEFAULT_COLUMN_MAX_WIDTHS),
  }
end

--- For tests. Puts the settings back into the unconfigured state.
function M._reset()
  current = nil
  notify.set_debug(false)
end

--- Layer the user's settings on top of the defaults. Unknown view types, action names and
--- column names are not taken in; a warning is issued instead.
--- Passing false as the key disables that binding, and false as the width removes that limit.
---@param opts table|nil
---@return docker.Config
local function merge(opts)
  local merged = defaults()
  if type(opts) ~= "table" then
    return merged
  end

  if opts.debug ~= nil then
    merged.debug = opts.debug and true or false
  end

  if type(opts.keymaps) == "table" then
    for view, bindings in pairs(opts.keymaps) do
      if merged.keymaps[view] == nil then
        notify.warn(("Unknown view kind in the configuration: %s"):format(tostring(view)))
      elseif type(bindings) == "table" then
        for action, key in pairs(bindings) do
          if merged.keymaps[view][action] == nil then
            notify.warn(("Unknown action name in the configuration: %s.%s"):format(tostring(view), tostring(action)))
          elseif key == false then
            merged.keymaps[view][action] = nil
          else
            merged.keymaps[view][action] = key
          end
        end
      end
    end
  end

  if opts.column_max_widths ~= nil and type(opts.column_max_widths) ~= "table" then
    notify.warn("column_max_widths must be a table of view kinds")
  elseif type(opts.column_max_widths) == "table" then
    for view, limits in pairs(opts.column_max_widths) do
      if merged.column_max_widths[view] == nil then
        notify.warn(("Unknown view kind in the configuration: %s"):format(tostring(view)))
      elseif type(limits) ~= "table" then
        notify.warn(("The column widths of %s must be a table of column names"):format(tostring(view)))
      else
        for column, width in pairs(limits) do
          if merged.column_max_widths[view][column] == nil then
            notify.warn(("Unknown column name in the configuration: %s.%s"):format(tostring(view), tostring(column)))
          elseif width == false then
            merged.column_max_widths[view][column] = nil
          elseif type(width) == "number" and width >= 1 and width % 1 == 0 then
            merged.column_max_widths[view][column] = width
          else
            notify.warn(("The column width must be a positive integer: %s.%s"):format(tostring(view), tostring(column)))
          end
        end
      end
    end
  end

  return merged
end

--- Take in the user's settings.
---@param opts table|nil
---@return docker.Config
function M.setup(opts)
  current = merge(opts)
  notify.set_debug(current.debug)
  return current
end

--- The current settings. Returns the defaults before `setup` is called.
---@return docker.Config
function M.get()
  if not current then
    current = defaults()
  end
  return current
end

return M
