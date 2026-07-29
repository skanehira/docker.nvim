--- フロートウィンドウの生成・リサイズ・重ね合わせ。
---
--- カラム見出しはバッファに入れず `winbar` に置く。見出し行をバッファに持たせると
--- カーソル行とデータ行の添字がずれ、行番号の補正が必要になる。
--- 重ね合わせは `zindex` で行い、上層を閉じたときに下層の内容とカーソル位置を残す。
local M = {}

---@class docker.Window
---@field bufnr integer
---@field winid integer

---@class docker.WindowOpts
---@field title string
---@field winbar string|nil
---@field zindex integer|nil

--- エディタに対する大きさの割合。
local WIDTH_RATIO = 0.8
local HEIGHT_RATIO = 0.8

--- 開いているウィンドウ。VimResized でまとめて追従させる。
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

--- フロートウィンドウを開く。
---@param opts docker.WindowOpts
---@return docker.Window
function M.open(opts)
  -- scratch バッファは buftype=nofile と swapfile=false を最初から持つ。
  -- 既定と異なる bufhidden と modifiable だけを明示する。
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

  -- 既定の NormalFloat は背景色を持つため、winbar だけが透過して見える。
  -- 本体と外枠をエディタの Normal に寄せ、背景を透過している環境では
  -- フロート全体が透ける。
  vim.wo[winid].winhighlight = "NormalFloat:Normal,FloatBorder:Normal"

  if opts.winbar then
    vim.wo[winid].winbar = opts.winbar
  end
  vim.wo[winid].cursorline = true

  local handle = { bufnr = bufnr, winid = winid }
  open_windows[winid] = handle
  return handle
end

--- 行を差し替える。書き込み不可のまま呼べるよう、一時的に解除して戻す。
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

--- ウィンドウを閉じる。既に閉じていても何もしない。
---@param handle docker.Window
function M.close(handle)
  open_windows[handle.winid] = nil
  if vim.api.nvim_win_is_valid(handle.winid) then
    vim.api.nvim_win_close(handle.winid, true)
  end
end

--- 開いている全てのフロートを閉じる。
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
