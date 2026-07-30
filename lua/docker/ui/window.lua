--- フロートウィンドウの生成・リサイズ・重ね合わせ。
---
--- カラム見出しはバッファに入れず `winbar` に置く。見出し行をバッファに持たせると
--- カーソル行とデータ行の添字がずれ、行番号の補正が必要になる。
--- 重ね合わせは `zindex` で行い、上層を閉じたときに下層の内容とカーソル位置を残す。
local M = {}

---@class docker.Window
---@field bufnr integer
---@field winid integer
---@field winbar_text string|nil  見出しの全文 (横スクロールで切り直すため保持する)
---@field winbar_watched boolean|nil

---@class docker.WindowOpts
---@field title string
---@field winbar string|nil
---@field zindex integer|nil
---@field wrap boolean|nil

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
  -- style="minimal" が入れる指定 (EndOfBuffer の打ち消し) は代入で消さず
  -- 追記する。消すと EndOfBuffer に背景色を持つカラースキームで
  -- データ行より下だけ別色になる。
  local minimal = vim.wo[winid].winhighlight
  local overrides = "NormalFloat:Normal,FloatBorder:Normal"
  vim.wo[winid].winhighlight = minimal ~= "" and (minimal .. "," .. overrides) or overrides

  if opts.wrap ~= nil then
    vim.wo[winid].wrap = opts.wrap
  end
  vim.wo[winid].cursorline = true

  local handle = { bufnr = bufnr, winid = winid }
  open_windows[winid] = handle
  if opts.winbar then
    M.set_winbar(handle, opts.winbar)
  end
  return handle
end

--- 先頭から指定した表示幅ぶんを落とす。バイト単位で切ると全角の見出しでずれる。
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

--- 現在の横スクロール量。
---@param winid integer
---@return integer
local function left_column(winid)
  return vim.api.nvim_win_call(winid, function()
    return vim.fn.winsaveview().leftcol
  end)
end

--- 保持した見出しを、今の横スクロール位置に合わせて描き直す。
---@param handle docker.Window
function M.sync_winbar(handle)
  if not handle.winbar_text or not vim.api.nvim_win_is_valid(handle.winid) then
    return
  end
  -- `%<` を末尾に置くと、はみ出したときに先頭ではなく末尾が落ちる。
  -- 既定は先頭を落とすため、右端でクリップされる本文と食い違う。
  local visible = drop_columns(handle.winbar_text, left_column(handle.winid))
  vim.wo[handle.winid].winbar = visible:gsub("%%", "%%%%") .. "%<"
end

--- 見出しを設定する。横スクロールしても列と食い違わないよう追従させる。
---@param handle docker.Window
---@param text string
function M.set_winbar(handle, text)
  handle.winbar_text = text
  M.sync_winbar(handle)

  if handle.winbar_watched then
    return
  end
  handle.winbar_watched = true
  -- WinScrolled は zl / zh を、CursorMoved はカーソル移動由来のスクロールを拾う。
  -- バッファローカルなので、バッファが消えれば一緒に消える。
  vim.api.nvim_create_autocmd({ "WinScrolled", "CursorMoved" }, {
    buffer = handle.bufnr,
    desc = "docker.nvim: 横スクロールに見出しを追従させる",
    callback = function()
      M.sync_winbar(handle)
    end,
  })
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
