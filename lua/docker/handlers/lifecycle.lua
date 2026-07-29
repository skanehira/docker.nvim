--- ビューの生成・表示・破棄とキーマップ設定。
---
--- 同じリソース種別のビューは 1 つだけ持つ。既に開いていれば新しいバッファを
--- 作らずそこへ移動する (US-026)。
--- キーマップは必ずバッファローカルに設定する。一覧ビュー以外のバッファで
--- プラグインのキーが作用しないようにするため (BR-014)。
local actions = require("docker.handlers.actions")
local cli = require("docker.adapters.docker.cli")
local help = require("docker.views.help")
local highlight = require("docker.ui.highlight")
local keymaps = require("docker.views.keymaps")
local list = require("docker.views.list")
local notify = require("docker.notify")
local operations = require("docker.handlers.operations")
local registry = require("docker.resources.registry")
local store = require("docker.state.store")
local view = require("docker.state.view")
local window = require("docker.ui.window")

local M = {}

---@class docker.ViewHandle
---@field kind string
---@field def docker.ResourceDefinition
---@field window docker.Window
---@field state docker.ViewState

--- 種別 -> 開いているビュー
---@type table<string, docker.ViewHandle>
local views = {}

---@param handle docker.ViewHandle
local function redraw(handle)
  list.render(handle.window, handle.def, handle.state.items, {
    busy = function(item)
      return operations.has_any(tostring(handle.def.id(item)))
    end,
  })
end

--- 一覧を取得してビューへ反映する。
---@param handle docker.ViewHandle
---@param on_done fun()|nil
local function fetch(handle, on_done)
  cli.run(handle.def.list_args(), function(result)
    if not result.ok then
      notify.error(result.error or "一覧の取得に失敗しました")
      if on_done then
        on_done()
      end
      return
    end

    store.replace_all(handle.kind, result.data)
    handle.state = view.with_items(handle.state, store.list(handle.kind))
    redraw(handle)
    if on_done then
      on_done()
    end
  end, { parse = "ndjson" })
end

--- カーソル行のリソースに対してアクションを実行する。
---@param handle docker.ViewHandle
---@param action string
local function dispatch(handle, action)
  if action == "close" then
    M.close(handle.kind)
    return
  end

  if action == "refresh" then
    fetch(handle)
    return
  end

  if action == "help" then
    local help_window = help.open(handle.def.view_type)
    -- ヘルプは `q` で閉じて直前の一覧へ戻る (BR-018)。
    vim.keymap.set("n", "q", function()
      window.close(help_window)
    end, { buffer = help_window.bufnr, nowait = true, silent = true, desc = "docker.nvim: ヘルプを閉じる" })
    return
  end

  local lnum = vim.api.nvim_win_get_cursor(handle.window.winid)[1]
  handle.state = view.with_cursor(handle.state, lnum)
  actions.execute(action, { def = handle.def, item = list.item_at(handle.state.items, lnum) })
end

---@param handle docker.ViewHandle
local function bind_keys(handle)
  for key, action in pairs(keymaps.resolve(handle.def.view_type)) do
    vim.keymap.set("n", key, function()
      dispatch(handle, action)
    end, {
      buffer = handle.window.bufnr,
      nowait = true,
      silent = true,
      desc = ("docker.nvim: %s"):format(action),
    })
  end
end

--- 一覧ビューを開く。既に開いていればそのウィンドウへ移動する。
---@param kind string
---@return docker.ViewHandle|nil
function M.open(kind)
  local def = registry.get(kind)
  if not def then
    notify.warn(("未対応のリソース種別です: %s"):format(tostring(kind)))
    return nil
  end

  local existing = views[kind]
  if existing and vim.api.nvim_win_is_valid(existing.window.winid) then
    vim.api.nvim_set_current_win(existing.window.winid)
    return existing
  end

  local opened
  cli.check_connection(function(result)
    if not result.ok then
      notify.error(result.error or "docker に接続できません")
      return
    end

    highlight.setup()
    local handle = {
      kind = kind,
      def = def,
      window = window.open({ title = def.display_name }),
      state = view.new(kind),
    }
    views[kind] = handle
    bind_keys(handle)
    fetch(handle)
    opened = handle
  end)

  return opened
end

--- 種別のビューを閉じる。開いていなければ何もしない。
---@param kind string
function M.close(kind)
  local handle = views[kind]
  if not handle then
    return
  end
  views[kind] = nil
  window.close(handle.window)
end

--- 開いている全てのビューを閉じる。
function M.close_all()
  for kind in pairs(views) do
    M.close(kind)
  end
  views = {}
end

--- 開いているビューを返す (テストと再描画で使う)。
---@param kind string
---@return docker.ViewHandle|nil
function M.get(kind)
  return views[kind]
end

return M
