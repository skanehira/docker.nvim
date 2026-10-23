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

--- Groups that are folded. While a filter is active the groups are expanded, so that a matching
--- resource hidden inside a folded group is still shown.
---@param handle docker.ViewHandle
---@return table<string, boolean>
local function collapsed_groups(handle)
  if (handle.state.filter or "") ~= "" then
    return {}
  end
  return handle.state.collapsed or {}
end

--- The rows currently drawn, in display order.
---@param handle docker.ViewHandle
---@return docker.ListEntry[]
local function layout(handle)
  return list.entries(handle.def, view.visible_items(handle.state, handle.def), {
    collapsed = collapsed_groups(handle),
  })
end

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
    collapsed = collapsed_groups(handle),
  })

  -- Keep the redraw from sending the cursor back to the first line.
  if cursor and vim.api.nvim_win_is_valid(handle.window.winid) then
    local last = math.max(vim.api.nvim_buf_line_count(handle.window.bufnr), 1)
    pcall(vim.api.nvim_win_set_cursor, handle.window.winid, { math.min(cursor[1], last), cursor[2] })
  end
end

--- Set the fold state of a group and redraw.
---@param handle docker.ViewHandle
---@param key string
---@param collapsed boolean
local function set_group_collapsed(handle, key, collapsed)
  local collapsed_set = vim.deepcopy(handle.state.collapsed or {})
  if collapsed then
    collapsed_set[key] = true
  else
    collapsed_set[key] = nil
  end
  handle.state = view.with_collapsed(handle.state, collapsed_set)
  redraw(handle)
end

--- Fold or expand a group and redraw.
---@param handle docker.ViewHandle
---@param key string
local function toggle_group(handle, key)
  set_group_collapsed(handle, key, not view.is_collapsed(handle.state, key))
end

--- The group key and the header line that the cursor line belongs to. A resource row belongs to
--- the group it is displayed under, so h on a child row can fold its parent.
---@param handle docker.ViewHandle
---@param entries docker.ListEntry[]
---@param lnum integer
---@param entry docker.ListEntry|nil
---@return string|nil key
---@return integer|nil header_lnum
local function group_of_line(handle, entries, lnum, entry)
  if entry and entry.group then
    return entry.group, lnum
  end
  if entry and entry.item and handle.def.group then
    local key = handle.def.group.key(entry.item)
    if type(key) == "string" and key ~= "" then
      for index, candidate in ipairs(entries) do
        if candidate.group == key then
          return key, index
        end
      end
    end
  end
  return nil, nil
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
      notify.error(result.error or "Failed to fetch the list")
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

  local list_args = assert(handle.def.list_args, "either list_args or load is required")
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
        notify.warn("The docker event subscription dropped. Retrying.")
      end
    end,
    on_reconnect = function()
      -- Some events were missed while waiting, so re-fetch everything to stay consistent.
      if views[handle.kind] then
        notify.info("The docker event subscription recovered.")
        fetch(handle)
      end
    end,
    on_giveup = function()
      notify.warn("Could not recover the event subscription. Press R to refresh manually.")
    end,
  })
end

--- Put the cursor on the corresponding line in the view we drilled down into.
---@param handle docker.ViewHandle
---@param match fun(item: table): boolean
local function focus_on(handle, match)
  local entries = layout(handle)

  local function find()
    for index, entry in ipairs(entries) do
      if entry.item and match(entry.item) then
        return index
      end
    end
    return nil
  end

  local index = find()
  if not index and handle.def.group then
    -- The target may be hidden inside a folded group. Expand only the groups that contain it,
    -- so the other groups keep the state the user chose.
    local collapsed = vim.deepcopy(handle.state.collapsed or {})
    local changed = false
    for _, item in ipairs(view.visible_items(handle.state, handle.def)) do
      if match(item) then
        local key = handle.def.group.key(item)
        if key and collapsed[key] then
          collapsed[key] = nil
          changed = true
        end
      end
    end
    if changed then
      handle.state = view.with_collapsed(handle.state, collapsed)
      -- The buffer still shows the folded rows until it is drawn again.
      redraw(handle)
      entries = layout(handle)
      index = find()
    end
  end

  if index then
    pcall(vim.api.nvim_win_set_cursor, handle.window.winid, { index, 0 })
    handle.state = view.with_cursor(handle.state, index)
  end
end

--- Decide where the cursor line can drill down to.
---@param handle docker.ViewHandle
---@return { kind: string, match: fun(item: table): boolean }|nil
local function drilldown_target(handle)
  local lnum = vim.api.nvim_win_get_cursor(handle.window.winid)[1]
  local entry = list.entry_at(layout(handle), lnum)
  local item = entry and entry.item
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

  local entries = layout(handle)
  local targets = {}
  for lnum = first, last do
    local entry = list.entry_at(entries, lnum)
    -- A group header is not a resource, so a selection that covers it deletes only the resources.
    if entry and entry.item then
      table.insert(targets, entry.item)
    end
  end

  if #targets == 0 then
    return
  end

  vim.ui.input({ prompt = ("Delete %d items? (y/N): "):format(#targets) }, function(answer)
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
            notify.info(("Deleted %d items"):format(#targets))
          else
            notify.error(("Could not delete %d items:\n%s"):format(#failures, table.concat(failures, "\n")))
          end
          fetch(handle)
        end
      end)
    end
  end)
end

--- Container list actions that operate on the whole project when the cursor is on a project row.
local PROJECT_ROW_ACTIONS = {
  start = "project_up",
  stop = "project_stop",
  restart = "project_restart",
  kill = "project_kill",
  delete = "project_down",
}

--- Every container of the group, regardless of the filter or fold state. A project operation
--- must not miss a container just because it is hidden by a filter.
---@param handle docker.ViewHandle
---@param key string
---@return table[]
local function group_items(handle, key)
  local items = {}
  for _, item in ipairs(handle.state.items) do
    if handle.def.group.key(item) == key then
      table.insert(items, item)
    end
  end
  return items
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
    vim.ui.input({ prompt = "Filter (empty to clear): ", default = handle.state.filter }, function(text)
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
      notify.warn("There is nothing to jump to from this row")
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
    vim.ui.select(choices, { prompt = "Resource kind to switch to" }, function(choice)
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
    end, { buffer = help_window.bufnr, nowait = true, silent = true, desc = "docker.nvim: close the help" })
    return
  end

  local lnum = vim.api.nvim_win_get_cursor(handle.window.winid)[1]
  handle.state = view.with_cursor(handle.state, lnum)
  local entries = layout(handle)
  local entry = list.entry_at(entries, lnum)

  if action == "expand_group" or action == "collapse_group" then
    local key, header_lnum = group_of_line(handle, entries, lnum, entry)
    if not key or not header_lnum then
      notify.warn("The cursor is not on a project row")
      return
    end

    if action == "expand_group" then
      if view.is_collapsed(handle.state, key) then
        set_group_collapsed(handle, key, false)
      end
      return
    end

    if not view.is_collapsed(handle.state, key) then
      set_group_collapsed(handle, key, true)
      -- When the group actually folded, a cursor left on a child row would point at a different
      -- line. Move it to the header. While a filter is active the group stays expanded, so the
      -- cursor stays where it is.
      if collapsed_groups(handle)[key] then
        pcall(vim.api.nvim_win_set_cursor, handle.window.winid, { header_lnum, 0 })
        handle.state = view.with_cursor(handle.state, header_lnum)
      end
    end
    return
  end

  if action == "inspect" then
    -- On a project row, <CR> folds or expands the group instead of opening the details.
    if entry and entry.group then
      toggle_group(handle, entry.group)
      return
    end
    local item = entry and entry.item
    if not item then
      notify.warn("No target to show details for")
      return
    end
    -- A service is not a docker object, so show the container it is tied to.
    if handle.kind == "service" then
      local container_id = tostring(item.container_id or "")
      if container_id == "" then
        notify.warn(("%s is not started, so its details cannot be shown"):format(tostring(item.name)))
        return
      end
      inspect.open(assert(registry.get("container")), { id = container_id, name = item.container })
      return
    end
    inspect.open(handle.def, item)
    return
  end

  if entry and entry.group then
    local project_action = PROJECT_ROW_ACTIONS[action]
    if project_action and handle.def.group and handle.def.group.project then
      actions.execute(project_action, {
        def = handle.def,
        project = entry.group,
        items = group_items(handle, entry.group),
      })
      return
    end
    notify.warn(("Unsupported operation on the project row: %s"):format(tostring(action)))
    return
  end

  actions.execute(action, {
    def = handle.def,
    item = entry and entry.item,
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
        desc = "docker.nvim: delete the selected rows at once",
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

--- Close the floats when focus moves to a plain window in their tab.
local function watch_focus()
  if focus_watching then
    return
  end
  focus_watching = true
  vim.api.nvim_create_autocmd("WinEnter", {
    group = focus_group,
    desc = "docker.nvim: close the float when focus leaves the list",
    callback = function()
      -- Keep it if the destination is a float. All of the plugin's views are floats, so
      -- this excludes moves to the inspect view, the help view and lists of other kinds (BR-018).
      -- It likewise excludes confirmation prompts in environments that implement
      -- vim.ui.input as a float.
      local winid = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_config(winid).relative ~= "" then
        return
      end
      local tabpage = vim.api.nvim_get_current_tabpage()
      for kind, handle in pairs(views) do
        if
          vim.api.nvim_win_is_valid(handle.window.winid)
          and vim.api.nvim_win_get_tabpage(handle.window.winid) == tabpage
        then
          M.close(kind)
        end
      end
      window.close_all(tabpage)
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
    notify.warn(("Unsupported resource kind: %s"):format(tostring(kind)))
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
      notify.error(result.error or "Cannot connect to docker")
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
      vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(handle.window.winid),
        once = true,
        desc = "docker.nvim: release the list when its window closes",
        callback = function()
          vim.schedule(function()
            if views[kind] == handle then
              M.close(kind)
            end
          end)
        end,
      })
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
        notify.error(loaded.error or "Failed to fetch the list")
        return finish(nil)
      end
      present(loaded)
    end

    local load = def.load
    if load then
      load({ cwd = cwd }, on_loaded)
      return
    end

    local list_args = assert(def.list_args, "either list_args or load is required")
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
