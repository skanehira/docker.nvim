--- Creating, resizing and stacking float windows.
---
--- Column headers are not put into the buffer but into the `winbar`. Keeping the header
--- line in the buffer would shift the cursor line against the data row index and would
--- require adjusting line numbers.
--- Stacking is done with `zindex`, so closing an upper layer keeps the content and the
--- cursor position of the layer below.
local highlight = require("docker.ui.highlight")

local M = {}

---@class docker.Window
---@field bufnr integer
---@field winid integer
---@field winbar_text string|nil  Full header text (kept so it can be re-clipped on horizontal scroll)
---@field winbar_watched boolean|nil

---@class docker.WindowOpts
---@field title string
---@field zindex integer|nil
---@field wrap boolean|nil

--- Size ratio relative to the editor.
local WIDTH_RATIO = 0.8
local HEIGHT_RATIO = 0.8

--- The open windows. They are all made to follow the editor size on VimResized.
---@type table<integer, docker.Window>
local open_windows = {}

local resize_group = vim.api.nvim_create_augroup("DockerNvimWindowResize", { clear = true })

---@return { width: integer, height: integer, row: integer, col: integer }
local function geometry()
  local width = math.max(math.floor(vim.o.columns * WIDTH_RATIO), 1)
  local height = math.max(math.floor(vim.o.lines * HEIGHT_RATIO), 1)
  return {
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
  }
end

vim.api.nvim_create_autocmd("VimResized", {
  group = resize_group,
  desc = "docker.nvim のフロートウィンドウをエディタの大きさに追従させる",
  callback = function()
    local size = geometry()
    for winid, handle in pairs(open_windows) do
      if vim.api.nvim_win_is_valid(winid) then
        local config = vim.api.nvim_win_get_config(winid)
        config.width = size.width
        config.height = size.height
        config.row = size.row
        config.col = size.col
        vim.api.nvim_win_set_config(winid, config)
      else
        open_windows[winid] = nil
        local _ = handle
      end
    end
  end,
})

--- Open a float window.
---@param opts docker.WindowOpts
---@return docker.Window
function M.open(opts)
  -- A scratch buffer already comes with buftype=nofile and swapfile=false.
  -- Only bufhidden and modifiable, which differ from the defaults, are set explicitly.
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].modifiable = false

  local size = geometry()
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = size.width,
    height = size.height,
    row = size.row,
    col = size.col,
    style = "minimal",
    border = "rounded",
    title = opts.title,
    title_pos = "center",
    zindex = opts.zindex,
  })

  -- The default NormalFloat has a background color, so only the winbar looks transparent.
  -- Aligning the body and the border with the editor's Normal makes the whole float
  -- transparent in setups where the background is transparent.
  -- What style="minimal" sets (cancelling out EndOfBuffer) is appended rather than
  -- overwritten by assignment. Dropping it would make everything below the data rows
  -- a different color under color schemes that give EndOfBuffer a background color.
  local minimal = vim.wo[winid].winhighlight
  local overrides = "NormalFloat:Normal,FloatBorder:Normal"
  vim.wo[winid].winhighlight = minimal ~= "" and (minimal .. "," .. overrides) or overrides

  if opts.wrap ~= nil then
    vim.wo[winid].wrap = opts.wrap
  end
  vim.wo[winid].cursorline = true

  local handle = { bufnr = bufnr, winid = winid }
  open_windows[winid] = handle
  return handle
end

--- Drop the given display width from the head. Cutting by bytes shifts full-width headers.
---@param text string
---@param columns integer
---@return string
local function drop_columns(text, columns)
  if columns <= 0 then
    return text
  end
  for index = 1, vim.fn.strchars(text) do
    if vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, index)) >= columns then
      return vim.fn.strcharpart(text, index)
    end
  end
  return ""
end

--- The current horizontal scroll amount.
---@param winid integer
---@return integer
local function left_column(winid)
  return vim.api.nvim_win_call(winid, function()
    return vim.fn.winsaveview().leftcol
  end)
end

--- Redraw the retained header for the current horizontal scroll position.
---@param handle docker.Window
function M.sync_winbar(handle)
  if not handle.winbar_text or not vim.api.nvim_win_is_valid(handle.winid) then
    return
  end
  -- Putting `%<` at the end drops the tail rather than the head when the text overflows.
  -- The default drops the head, which disagrees with the body that is clipped at the right edge.
  local visible = drop_columns(handle.winbar_text, left_column(handle.winid))
  local escaped = visible:gsub("%%", "%%%%")
  vim.wo[handle.winid].winbar = "%#" .. highlight.header_group() .. "#" .. escaped .. "%*%<"
end

--- Set the header. It follows horizontal scrolling so it never disagrees with the columns.
---@param handle docker.Window
---@param text string
function M.set_winbar(handle, text)
  handle.winbar_text = text
  M.sync_winbar(handle)

  if handle.winbar_watched then
    return
  end
  handle.winbar_watched = true
  -- WinScrolled picks up zl / zh, CursorMoved picks up scrolling caused by cursor movement.
  -- These are buffer-local, so they go away together with the buffer.
  vim.api.nvim_create_autocmd({ "WinScrolled", "CursorMoved" }, {
    buffer = handle.bufnr,
    desc = "docker.nvim: 横スクロールに見出しを追従させる",
    callback = function()
      M.sync_winbar(handle)
    end,
  })
end

--- Replace the lines. Writability is temporarily lifted and restored so this can be called
--- while the buffer stays non-modifiable.
---@param handle docker.Window
---@param lines string[]
function M.set_lines(handle, lines)
  if not vim.api.nvim_buf_is_valid(handle.bufnr) then
    return
  end
  vim.bo[handle.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(handle.bufnr, 0, -1, false, lines)
  vim.bo[handle.bufnr].modifiable = false
end

--- Close the window. Does nothing if it is already closed.
---@param handle docker.Window
function M.close(handle)
  open_windows[handle.winid] = nil
  if vim.api.nvim_win_is_valid(handle.winid) then
    vim.api.nvim_win_close(handle.winid, true)
  end
end

--- Close every open float.
function M.close_all()
  local handles = {}
  for _, handle in pairs(open_windows) do
    table.insert(handles, handle)
  end
  for _, handle in ipairs(handles) do
    M.close(handle)
  end
end

return M
