--- ビューの生成・表示・破棄とキーマップ設定。
---
--- 同じリソース種別のビューは 1 つだけ持つ。既に開いていれば新しいバッファを
--- 作らずそこへ移動する (US-026)。
--- キーマップは必ずバッファローカルに設定する。一覧ビュー以外のバッファで
--- プラグインのキーが作用しないようにするため (BR-014)。
local actions = require("docker.handlers.actions")
local cli = require("docker.adapters.docker.cli")
local events = require("docker.adapters.docker.events")
local help = require("docker.views.help")
local highlight = require("docker.ui.highlight")
local inspect = require("docker.views.inspect")
local keymaps = require("docker.views.keymaps")
local list = require("docker.views.list")
local notify = require("docker.notify")
local operations = require("docker.handlers.operations")
local registry = require("docker.resources.registry")
local render = require("docker.handlers.render")
local store = require("docker.state.store")
local view = require("docker.state.view")
local window = require("docker.ui.window")

local M = {}

---@class docker.ViewHandle
---@field kind string
---@field def docker.ResourceDefinition
---@field window docker.Window
---@field state docker.ViewState
---@field subscription docker.EventSubscription|nil
---@field cwd string                       ビューを開いた時点の作業ディレクトリ (BR-003)
---@field project docker.ComposeProject|nil compose サービス一覧のときのみ

--- 種別 -> 開いているビュー
---@type table<string, docker.ViewHandle>
local views = {}

--- 接続確認の応答を待っている種別。docker への問い合わせは非同期なので、
--- 応答前にもう一度開こうとするとフロートが二重に開く。
---@type table<string, boolean>
local opening = {}

--- カーソル位置を保ったまま描き直す。
---@param handle docker.ViewHandle
local function redraw(handle)
  if not vim.api.nvim_buf_is_valid(handle.window.bufnr) then
    return
  end

  local cursor
  if vim.api.nvim_win_is_valid(handle.window.winid) then
    cursor = vim.api.nvim_win_get_cursor(handle.window.winid)
  end

  list.render(handle.window, handle.def, view.visible_items(handle.state, handle.def), {
    busy = function(item)
      return operations.has_any(tostring(handle.def.id(item)))
    end,
  })

  -- 再描画でカーソルが先頭へ戻らないようにする。
  if cursor and vim.api.nvim_win_is_valid(handle.window.winid) then
    local last = math.max(vim.api.nvim_buf_line_count(handle.window.bufnr), 1)
    pcall(vim.api.nvim_win_set_cursor, handle.window.winid, { math.min(cursor[1], last), cursor[2] })
  end
end

--- 種別のビューを描き直す (外部から状態が変わったとき用)。
---@param kind string
function M.refresh_view(kind)
  local handle = views[kind]
  if handle then
    redraw(handle)
  end
end

--- 一覧を取得してビューへ反映する。
---@param handle docker.ViewHandle
---@param on_done fun()|nil
local function fetch(handle, on_done)
  local function apply(result)
    if not result.ok then
      notify.error(result.error or "一覧の取得に失敗しました")
      if on_done then
        on_done()
      end
      return
    end

    -- サービス一覧は compose の解決結果 (プロジェクト名と作業ディレクトリ) も持ち帰る。
    if result.project then
      handle.project = result.project
    end
    store.replace_all(handle.kind, result.data)
    handle.state = view.with_items(handle.state, store.list(handle.kind))
    redraw(handle)
    if on_done then
      on_done()
    end
  end

  local load = handle.def.load
  if load then
    load({ cwd = handle.cwd }, apply)
    return
  end

  local list_args = assert(handle.def.list_args, "list_args か load のどちらかが必要")
  cli.run(list_args(), apply, { parse = "ndjson" })
end

--- 対象が消えたことを示すイベントか。
---@param action string
---@return boolean
local function is_removal(action)
  return action == "destroy" or action == "delete" or action == "remove" or action == "prune"
end

--- イベントで変わった 1 件だけを取り直してストアへ反映する。
---@param handle docker.ViewHandle
---@param event docker.Event
local function apply_event(handle, event)
  -- 組み立てが必要な種別 (サービス) は 1 件の取り直しでは表せないので全件やり直す。
  if handle.def.load then
    render.request(handle.kind, function()
      if views[handle.kind] then
        fetch(views[handle.kind])
      end
    end)
    return
  end

  local function schedule_redraw()
    render.request(handle.kind, function()
      local current = views[handle.kind]
      if current then
        current.state = view.with_items(current.state, store.list(current.kind))
        redraw(current)
      end
    end)
  end

  if is_removal(event.action) then
    store.remove(handle.kind, event.id)
    schedule_redraw()
    return
  end

  local item_args = handle.def.item_args
  if not item_args then
    return
  end

  cli.run(item_args(event.id), function(result)
    -- 取得できないのは既に消えた場合が大半。利用者へは通知せず一覧から取り除く。
    if not result.ok or type(result.data) ~= "table" or #result.data == 0 then
      store.remove(handle.kind, event.id)
    else
      store.upsert(handle.kind, result.data[1])
    end
    schedule_redraw()
  end, { parse = "ndjson" })
end

--- そのビューのイベント購読を始める。
---@param handle docker.ViewHandle
local function subscribe_events(handle)
  handle.subscription = events.subscribe({
    on_event = function(event)
      if event.type == handle.def.event_type and views[handle.kind] then
        apply_event(handle, event)
      end
    end,
    on_disconnect = function(intentional)
      if not intentional then
        notify.warn("docker のイベント購読が切断されました。再接続を試みます。")
      end
    end,
    on_reconnect = function()
      -- 待機中に取りこぼした分があるため、全件取り直して整合させる。
      if views[handle.kind] then
        notify.info("docker のイベント購読が回復しました。")
        fetch(handle)
      end
    end,
    on_giveup = function()
      notify.warn("イベント購読を回復できませんでした。R で手動更新してください。")
    end,
  })
end

--- 辿った先で、対応する行へカーソルを合わせる。
---@param handle docker.ViewHandle
---@param match fun(item: table): boolean
local function focus_on(handle, match)
  local visible = view.visible_items(handle.state, handle.def)
  for index, item in ipairs(visible) do
    if match(item) then
      pcall(vim.api.nvim_win_set_cursor, handle.window.winid, { index, 0 })
      handle.state = view.with_cursor(handle.state, index)
      return
    end
  end
end

--- カーソル行から辿れる先を決める。
---@param handle docker.ViewHandle
---@return { kind: string, match: fun(item: table): boolean }|nil
local function drilldown_target(handle)
  local lnum = vim.api.nvim_win_get_cursor(handle.window.winid)[1]
  local item = list.item_at(view.visible_items(handle.state, handle.def), lnum)
  if not item then
    return nil
  end

  if handle.kind == "container" then
    -- コンテナ -> そのイメージ
    local image = tostring(item.image or "")
    if image == "" then
      return nil
    end
    return {
      kind = "image",
      match = function(candidate)
        local ref = ("%s:%s"):format(tostring(candidate.repository), tostring(candidate.tag))
        return ref == image or tostring(candidate.id) == image
      end,
    }
  end

  if handle.kind == "image" then
    -- イメージ -> それを使うコンテナ
    local ref = ("%s:%s"):format(tostring(item.repository), tostring(item.tag))
    return {
      kind = "container",
      match = function(candidate)
        return tostring(candidate.image) == ref
      end,
    }
  end

  if handle.kind == "service" then
    -- サービス -> そのコンテナ
    local container_id = tostring(item.container_id or "")
    if container_id == "" then
      return nil
    end
    return {
      kind = "container",
      match = function(candidate)
        return tostring(candidate.id) == container_id
      end,
    }
  end

  return nil
end

--- 選択範囲のリソースをまとめて削除する。
--- 一部が失敗しても他は実行し、失敗分をまとめて知らせる (原子性は保証しない)。
---@param handle docker.ViewHandle
local function bulk_delete(handle)
  -- Visual モードを抜けてから範囲を取る (抜けないと '< '> が更新されない)。
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  local first = vim.fn.line("'<")
  local last = vim.fn.line("'>")

  local visible = view.visible_items(handle.state, handle.def)
  local targets = {}
  for lnum = first, last do
    local item = list.item_at(visible, lnum)
    if item then
      table.insert(targets, item)
    end
  end

  if #targets == 0 then
    return
  end

  vim.ui.input({ prompt = ("%d 件を削除しますか? (y/N): "):format(#targets) }, function(answer)
    if answer ~= "y" and answer ~= "Y" then
      return
    end

    local remaining = #targets
    local failures = {}
    for _, item in ipairs(targets) do
      local delete_args = assert(handle.def.delete_args)
      cli.run(delete_args(item), function(result)
        if not result.ok then
          table.insert(failures, ("%s: %s"):format(tostring(item.name or item.id), result.error))
        end
        remaining = remaining - 1
        if remaining == 0 then
          if #failures == 0 then
            notify.info(("%d 件を削除しました"):format(#targets))
          else
            notify.error(
              ("%d 件が削除できませんでした:\n%s"):format(#failures, table.concat(failures, "\n"))
            )
          end
          fetch(handle)
        end
      end)
    end
  end)
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
    -- 切れた購読はここで戻す (G10)。生きている購読は張り直さない。
    if not handle.subscription or not handle.subscription.is_alive() then
      subscribe_events(handle)
    end
    return
  end

  if action == "filter" then
    vim.ui.input({ prompt = "絞り込み (空で解除): ", default = handle.state.filter }, function(text)
      if text == nil then
        return
      end
      handle.state = view.with_filter(handle.state, vim.trim(text))
      redraw(handle)
    end)
    return
  end

  if action == "drilldown" then
    local target = drilldown_target(handle)
    if not target then
      notify.warn("この行から辿れる先がありません")
      return
    end
    M.open(target.kind, function(opened)
      if opened then
        -- 辿った先で対象の行へカーソルを移す。
        focus_on(opened, target.match)
      end
    end)
    return
  end

  if action == "delete" and vim.fn.mode():lower():find("v") then
    bulk_delete(handle)
    return
  end

  if action == "switch_view" then
    -- 切替先を選ばせ、同じ流れで開く (今のビューは閉じる)。
    local choices = registry.subcommands()
    vim.ui.select(choices, { prompt = "切り替え先のリソース種別" }, function(choice)
      if not choice then
        return
      end
      local target = registry.by_subcommand(choice)
      if not target or target.kind == handle.kind then
        return
      end
      M.open(target.kind, function(opened)
        -- 切替に成功したときだけ元のビューを閉じる。
        -- compose プロジェクト外などで開けなかった場合に、今のビューを失わせない。
        if opened then
          M.close(handle.kind)
        end
      end)
    end)
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
  local visible = view.visible_items(handle.state, handle.def)

  if action == "inspect" then
    local item = list.item_at(visible, lnum)
    if item then
      inspect.open(handle.def, item)
    else
      notify.warn("詳細を表示する対象がありません")
    end
    return
  end

  actions.execute(action, {
    def = handle.def,
    item = list.item_at(visible, lnum),
    cwd = handle.cwd,
    project = handle.project,
  })
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

--- テスト用。キー操作に相当する振り分けを直接呼ぶ。
---@param handle docker.ViewHandle
---@param action string
function M.dispatch_for_test(handle, action)
  dispatch(handle, action)
end

--- 一覧ビューを開く。既に開いていればそのウィンドウへ移動する。
--- docker への接続確認が非同期なので、開き終わりは `on_open` で受け取る。
---@param kind string
---@param on_open fun(handle: docker.ViewHandle|nil)|nil
function M.open(kind, on_open)
  local function done(handle)
    if on_open then
      on_open(handle)
    end
  end

  local def = registry.get(kind)
  if not def then
    notify.warn(("未対応のリソース種別です: %s"):format(tostring(kind)))
    return done(nil)
  end

  local existing = views[kind]
  if existing and vim.api.nvim_win_is_valid(existing.window.winid) then
    vim.api.nvim_set_current_win(existing.window.winid)
    return done(existing)
  end

  -- 応答を待っている間に再度開こうとしても、フロートを二重に作らない。
  if opening[kind] then
    return done(nil)
  end
  opening[kind] = true

  cli.check_connection(function(result)
    opening[kind] = nil

    if not result.ok then
      notify.error(result.error or "docker に接続できません")
      return done(nil)
    end

    -- compose の解決は開いた時点の作業ディレクトリで固定する (BR-003)。
    local cwd = vim.fn.getcwd()

    -- 最初の取得が成功してからウィンドウを開く。compose プロジェクト外や
    -- 取得失敗のときに空のフロートだけが残らないようにする (7.3)。
    local function present(loaded)
      highlight.setup()
      local handle = {
        kind = kind,
        def = def,
        cwd = cwd,
        project = loaded.project,
        window = window.open({ title = def.display_name }),
        state = view.new(kind),
      }
      views[kind] = handle
      bind_keys(handle)
      store.replace_all(kind, loaded.data)
      handle.state = view.with_items(handle.state, store.list(kind))
      redraw(handle)
      subscribe_events(handle)
      done(handle)
    end

    local function on_loaded(loaded)
      if not loaded.ok then
        notify.error(loaded.error or "一覧の取得に失敗しました")
        return done(nil)
      end
      present(loaded)
    end

    local load = def.load
    if load then
      load({ cwd = cwd }, on_loaded)
      return
    end

    local list_args = assert(def.list_args, "list_args か load のどちらかが必要")
    cli.run(list_args(), on_loaded, { parse = "ndjson" })
  end)
end

--- 種別のビューを閉じる。開いていなければ何もしない。
---@param kind string
function M.close(kind)
  local handle = views[kind]
  if not handle then
    return
  end
  views[kind] = nil
  render.cancel(kind)
  if handle.subscription then
    handle.subscription.stop()
    handle.subscription = nil
  end
  window.close(handle.window)
end

--- 開いている全てのビューを閉じる。
function M.close_all()
  for kind in pairs(views) do
    M.close(kind)
  end
  views = {}
  opening = {}
end

--- 開いているビューを返す。
---@param kind string
---@return docker.ViewHandle|nil
function M.get(kind)
  return views[kind]
end

--- 実行中の操作が変わったら、その種別の一覧を描き直す。
--- これが無いと「実行中」の印が画面に出ない。
operations.subscribe(function()
  for kind in pairs(views) do
    M.refresh_view(kind)
  end
end)

return M
