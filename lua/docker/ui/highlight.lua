--- Highlighting of the status column.
---
--- The groups are linked to existing highlights. Specifying colors directly would clash
--- with the user's color scheme, so they are mapped onto the standard groups that are
--- closest in meaning.
local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("docker_nvim_highlight")

local UNKNOWN_GROUP = "DockerStatusUnknown"

--- State -> highlight group.
local GROUPS = {
  running = "DockerStatusRunning",
  exited = "DockerStatusExited",
  paused = "DockerStatusPaused",
  created = "DockerStatusCreated",
  restarting = "DockerStatusRestarting",
  dead = "DockerStatusDead",
  none = "DockerStatusNone",
}

--- Group -> the standard highlight it links to.
local LINKS = {
  DockerStatusRunning = "DiagnosticOk",
  DockerStatusExited = "Comment",
  DockerStatusPaused = "DiagnosticWarn",
  DockerStatusCreated = "DiagnosticHint",
  DockerStatusRestarting = "DiagnosticWarn",
  DockerStatusDead = "DiagnosticError",
  DockerStatusNone = "Comment",
  [UNKNOWN_GROUP] = "Normal",
}

--- Colors of the column header. Unlike the state groups there is no standard group that is
--- close in meaning, so the same color as the reference denops-docker.vim is specified directly.
--- Bold and underline are not applied (denops-docker.vim only specifies them for cterm, so in a
--- termguicolors setup only the color takes effect; this matches that appearance).
local HEADER_GROUP = "DockerHeader"
local HEADER_HL = { fg = "#e2a478", ctermfg = 216 }

---@return integer
function M.namespace()
  return NAMESPACE
end

--- The name of the highlight group for the column header.
---@return string
function M.header_group()
  return HEADER_GROUP
end

--- Define the highlight groups. Groups the user has already defined are not overwritten.
function M.setup()
  for group, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
  vim.api.nvim_set_hl(0, HEADER_GROUP, vim.tbl_extend("force", HEADER_HL, { default = true }))
end

--- Return the name of the highlight group that corresponds to the state.
---@param state string|nil
---@return string
function M.group_for(state)
  if type(state) ~= "string" then
    return UNKNOWN_GROUP
  end
  return GROUPS[state:lower()] or UNKNOWN_GROUP
end

--- Apply a highlight to the given byte range of the given line.
--- Does nothing when the range is empty (a zero-length extmark carries no meaning).
---@param bufnr integer
---@param line integer 0-based line number
---@param from integer Start byte position
---@param to integer   End byte position (exclusive)
---@param group string
function M.apply(bufnr, line, from, to, group)
  if to <= from then
    return
  end
  vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, line, from, {
    end_col = to,
    hl_group = group,
  })
end

--- Clear every highlight this plugin has applied.
---@param bufnr integer
function M.clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
end

return M
