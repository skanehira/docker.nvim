--- Creation, display and disposal of views, plus keymap setup.
---
--- Only one view is kept per resource kind. If it is already open, move to that
--- window instead of creating a new buffer (US-026).
--- Keymaps are always set buffer-locally, so that the plugin's keys do not take
--- effect in buffers other than the list views (BR-014).
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
---@field cwd string                       working directory at the time the view was opened (BR-003)
---@field last_warning string|nil          the warning reported last time; kept so the same text is not repeated

--- kind -> the view that is open
---@type table<string, docker.ViewHandle>
local views = {}

--- Kinds that are waiting for the connection check to answer. Queries to docker are
--- asynchronous, so trying to open again before the answer arrives opens two floats.
---@type table<string, boolean>
local opening = {}

--- Redraw while keeping the cursor position.
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

  -- Keep the redraw from sending the cursor back to the first line.
  if cursor and vim.api.nvim_win_is_valid(handle.window.winid) then
    local last = math.max(vim.api.nvim_buf_line_count(handle.window.bufnr), 1)
    pcall(vim.api.nvim_win_set_cursor, handle.window.winid, { math.min(cursor[1], last), cursor[2] })
  end
end

--- Redraw the view of a kind (for when the state is changed from the outside).
---@param kind string
function M.refresh_view(kind)
  local handle = views[kind]
  if handle then
    redraw(handle)
  end
end

--- Notification for when the list can still be shown but there is something to report.
--- The list is re-fetched on every event, so emitting the same text as-is would pile up.
---@param handle docker.ViewHandle
---@param warning string|nil
local function announce_warning(handle, warning)
  if warning and warning ~= handle.last_warning then
    notify.warn(warning)
  end
  handle.last_warning = warning
end

--- Fetch the list and reflect it into the view.
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

    announce_warning(handle, result.warning)
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

--- Whether the event indicates that the target has disappeared.
---@param action string
---@return boolean
local function is_removal(action)
  return action == "destroy" or action == "delete" or action == "remove" or action == "prune"
end

--- Re-fetch only the single item changed by the event and reflect it into the store.
---@param handle docker.ViewHandle
---@param event docker.Event
local function apply_event(handle, event)
  -- Kinds that need assembling (services) and kinds whose event ID does not correspond
  -- to the identifier (images) cannot be expressed by re-fetching one item, so refetch all.
  if handle.def.load or handle.def.event_reload then
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
    -- Failing to fetch mostly means it is already gone. Drop it from the list without notifying the user.
    if not result.ok or type(result.data) ~= "table" or #result.data == 0 then
      store.remove(handle.kind, event.id)
    else
      store.upsert(handle.kind, result.data[1])
    end
    schedule_redraw()
  end, { parse = "ndjson" })
end

--- Start subscribing to events for that view.
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
      -- Some events were missed while waiting, so re-fetch everything to stay consistent.
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

--- Put the cursor on the corresponding line in the view we drilled down into.
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

--- Decide where the cursor line can drill down to.
---@param handle docker.ViewHandle
---@return { kind: string, match: fun(item: table): boolean }|nil
local function drilldown_target(handle)
  local lnum = vim.api.nvim_win_get_cursor(handle.window.winid)[1]
  local item = list.item_at(view.visible_items(handle.state, handle.def), lnum)
  if not item then
    return nil
  end

  if handle.kind == "container" then
    -- container -> its image
    local image = tostring(item.image or "")
    if image == "" then
      return nil
    end
    -- The .Image of `docker ps` can come back with the tag omitted, such as "alpine".
    -- The image list side has repository and tag, so match against both spellings.
    return {
      kind = "image",
      match = function(candidate)
        local repository = tostring(candidate.repository)
        local ref = ("%s:%s"):format(repository, tostring(candidate.tag))
        return ref == image or repository == image or tostring(candidate.id) == image
      end,
    }
  end

  if handle.kind == "image" then
    -- image -> the containers that use it
    local ref = ("%s:%s"):format(tostring(item.repository), tostring(item.tag))
    return {
      kind = "container",
      match = function(candidate)
        return tostring(candidate.image) == ref
      end,
    }
  end

  if handle.kind == "service" then
    -- service -> its container
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

--- Delete the resources in the selected range all at once.
--- Even if some fail, the rest still run, and the failures are reported together
--- (atomicity is not guaranteed).
---@param handle docker.ViewHandle
local function bulk_delete(handle)
  -- Leave Visual mode before taking the range ('< and '> are not updated until we leave).
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

--- Run an action against the resource on the cursor line.
---@param handle docker.ViewHandle
---@param action string
local function dispatch(handle, action)
  if action == "close" then
    M.close(handle.kind)
    return
  end

  if action == "refresh" then
    fetch(handle)
    -- Restore a dropped subscription here (G10). A live subscription is not re-established.
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
        -- Move the cursor to the target line in the view we drilled down into.
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
    -- Let the user pick the switch target and open it through the same flow (the current view is closed).
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
        -- Close the original view only when the switch succeeded.
        -- This keeps the current view from being lost when the target could not be
        -- opened, for example outside a compose project.
        if opened then
          M.close(handle.kind)
        end
      end)
    end)
    return
  end

  if action == "help" then
    local help_window = help.open(handle.def.view_type)
    -- Help closes with `q` and returns to the list that was in front of it (BR-018).
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
    if not item then
      notify.warn("詳細を表示する対象がありません")
      return
    end
    -- A service is not a docker object, so show the container it is tied to.
    if handle.kind == "service" then
      local container_id = tostring(item.container_id or "")
      if container_id == "" then
        notify.warn(("%s は起動していないため詳細を表示できません"):format(tostring(item.name)))
        return
      end
      inspect.open(assert(registry.get("container")), { id = container_id, name = item.container })
      return
    end
    inspect.open(handle.def, item)
    return
  end

  actions.execute(action, {
    def = handle.def,
    item = list.item_at(visible, lnum),
  })
end

---@param handle docker.ViewHandle
local function bind_keys(handle)
  local resolved = keymaps.resolve(handle.def.view_type)
  for key, action in pairs(resolved) do
    vim.keymap.set("n", key, function()
      dispatch(handle, action)
    end, {
      buffer = handle.window.bufnr,
      nowait = true,
      silent = true,
      desc = ("docker.nvim: %s"):format(action),
    })

    -- Bulk delete acts on a selected range, so map it in Visual mode too.
    -- With Normal mode alone, selecting and pressing the key never reaches the plugin.
    if action == "delete" then
      vim.keymap.set("x", key, function()
        bulk_delete(handle)
      end, {
        buffer = handle.window.bufnr,
        nowait = true,
        silent = true,
        desc = "docker.nvim: 選択範囲をまとめて削除",
      })
    end
  end
end

--- For tests. Calls the dispatch equivalent to a key press directly.
---@param handle docker.ViewHandle
---@param action string
function M.dispatch_for_test(handle, action)
  dispatch(handle, action)
end

local focus_group = vim.api.nvim_create_augroup("DockerNvimViewFocus", { clear = true })
local focus_watching = false

--- Stop watching window moves. Do not keep it resident while no view is open.
local function unwatch_focus()
  if not focus_watching then
    return
  end
  focus_watching = false
  vim.api.nvim_clear_autocmds({ group = focus_group })
end

--- Close the float once focus moves outside the list.
--- Keeps the list from lingering behind after a log or shell terminal is opened.
local function watch_focus()
  if focus_watching then
    return
  end
  focus_watching = true
  vim.api.nvim_create_autocmd("WinEnter", {
    group = focus_group,
    desc = "docker.nvim: 一覧の外へフォーカスが移ったらフロートを閉じる",
    callback = function()
      -- Keep it if the destination is a float. All of the plugin's views are floats, so
      -- this excludes moves to the inspect view, the help view and lists of other kinds (BR-018).
      -- It likewise excludes confirmation prompts in environments that implement
      -- vim.ui.input as a float.
      local winid = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_config(winid).relative ~= "" then
        return
      end
      M.close_all()
    end,
  })
end

--- Open the list view. If it is already open, move to that window.
--- The connection check against docker is asynchronous, so the completion of the open
--- is received through `on_open`.
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

  -- Trying to open again while waiting for the answer must not create a second float.
  if opening[kind] then
    return done(nil)
  end
  opening[kind] = true

  --- Accept requests again once the open finishes (whether it succeeded or failed).
  --- Releasing it right after the connection check would leave views[kind] nil until the
  --- list is fetched, and a second float would open during that window.
  local function finish(handle)
    opening[kind] = nil
    done(handle)
  end

  cli.check_connection(function(result)
    if not result.ok then
      notify.error(result.error or "docker に接続できません")
      return finish(nil)
    end

    -- The project of the working directory to merge in is fixed at the time of opening (BR-003).
    -- Re-reading it on every event-driven refetch would make the list shift by whatever
    -- was cd'd into in the meantime.
    local cwd = vim.fn.getcwd()

    -- Open the window only after the first fetch succeeds, so that a failed fetch does not
    -- leave nothing but an empty float (7.3).
    local function present(loaded)
      highlight.setup()
      -- If the view is closed and reopened while waiting for the answer, requests are
      -- accepted again and we reach this point twice. Without closing the older one,
      -- an orphaned float is left behind.
      M.close(kind)
      local handle = {
        kind = kind,
        def = def,
        cwd = cwd,
        -- With wrapping, one row becomes two screen lines and the columns stop lining up
        -- with the winbar header.
        window = window.open({ title = def.display_name, wrap = false }),
        state = view.new(kind),
      }
      views[kind] = handle
      bind_keys(handle)
      watch_focus()
      store.replace_all(kind, loaded.data)
      handle.state = view.with_items(handle.state, store.list(kind))
      redraw(handle)
      subscribe_events(handle)
      announce_warning(handle, loaded.warning)
      finish(handle)
    end

    local function on_loaded(loaded)
      if not loaded.ok then
        notify.error(loaded.error or "一覧の取得に失敗しました")
        return finish(nil)
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

--- Close the view of a kind. Does nothing if it is not open.
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
  -- Drop the watcher too once the last one is closed. Leaving it to the focus move caused
  -- by the close would leave only the watcher behind when the destination is a float.
  if next(views) == nil then
    unwatch_focus()
  end
  window.close(handle.window)
end

--- Close every open view.
function M.close_all()
  -- Stop the watcher first, so the focus move caused by closing does not re-enter here.
  unwatch_focus()
  for kind in pairs(views) do
    M.close(kind)
  end
  views = {}
  opening = {}
  -- The inspect and help views are not tracked in `views`, so clean them up together here.
  window.close_all()
end

--- Return the open view.
---@param kind string
---@return docker.ViewHandle|nil
function M.get(kind)
  return views[kind]
end

--- Redraw the list of a kind whenever the set of in-flight operations changes.
--- Without this, the busy marker never appears on screen.
operations.subscribe(function()
  for kind in pairs(views) do
    M.refresh_view(kind)
  end
end)

return M
