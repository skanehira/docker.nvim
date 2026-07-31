local cli = require("docker.adapters.docker.cli")
local config = require("docker.config")
local events = require("docker.adapters.docker.events")
local jobs = require("docker.handlers.jobs")
local lifecycle = require("docker.handlers.lifecycle")
local store = require("docker.state.store")

describe("manual refetch and view cleanup", function()
  local runs
  local original_notify
  local notified
  local event_handlers
  local subscriptions

  --- A fake docker that returns NDJSON for n containers.
  ---@param count integer
  local function stub_docker(count)
    cli._set_executor(function(cmd, _, on_exit)
      table.insert(runs, cmd)
      if cmd[2] == "version" then
        on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
        return
      end
      local rows = {}
      for i = 1, count do
        table.insert(
          rows,
          ('{"id":"id%d","name":"c%d","image":"alpine","state":"running","status":"Up",'):format(i, i)
            .. '"ports":"","command":"x","created_at":"now","compose_project":"","compose_service":"","compose_oneoff":""}'
        )
      end
      on_exit({ code = 0, stdout = table.concat(rows, "\n") .. "\n", stderr = "" })
    end)
  end

  ---@return docker.ViewHandle
  local function open_view()
    local captured, called = nil, false
    lifecycle.open("container", function(handle)
      captured, called = handle, true
    end)
    assert(vim.wait(3000, function()
      return called
    end))
    return assert(captured)
  end

  before_each(function()
    runs, notified, event_handlers, subscriptions = {}, {}, {}, {}
    config._reset()
    store._reset()
    jobs._reset()
    jobs._set_stopper(function() end)
    lifecycle.close_all()
    original_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end
    stub_docker(3)
    events._set_starter(function(_, handlers)
      table.insert(event_handlers, handlers)
      table.insert(subscriptions, 900 + #subscriptions)
      return 900 + #subscriptions - 1
    end)
    events._set_waiter(function() end)
  end)

  after_each(function()
    lifecycle.close_all()
    vim.notify = original_notify
    cli._set_executor(nil)
    events._set_starter(nil)
    events._set_waiter(nil)
    jobs._reset()
    config._reset()
    store._reset()
  end)

  ---@return integer
  local function list_fetch_count()
    local count = 0
    for _, cmd in ipairs(runs) do
      if cmd[2] == "ps" and not vim.tbl_contains(cmd, "--filter") then
        count = count + 1
      end
    end
    return count
  end

  describe("refresh", function()
    it("refetches the list", function()
      local handle = open_view()
      local before = list_fetch_count()

      lifecycle.dispatch_for_test(handle, "refresh")
      vim.wait(200)

      assert.are.equal(before + 1, list_fetch_count())
    end)

    it("reflects the refetched content on the screen", function()
      local handle = open_view()
      assert.are.equal(3, #vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false))

      stub_docker(5)
      lifecycle.dispatch_for_test(handle, "refresh")
      vim.wait(200)

      assert.are.equal(5, #vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false))
    end)

    it("keeps the cursor position across a refetch", function()
      local handle = open_view()
      vim.api.nvim_win_set_cursor(handle.window.winid, { 3, 0 })

      lifecycle.dispatch_for_test(handle, "refresh")
      vim.wait(200)

      assert.are.equal(3, vim.api.nvim_win_get_cursor(handle.window.winid)[1])
    end)

    it("restarts the subscription when it has stopped", function()
      -- G10: on top of refetching the list, R restores a subscription that has been cut.
      local handle = open_view()
      assert.are.equal(1, #event_handlers)
      assert(handle.subscription).stop()

      lifecycle.dispatch_for_test(handle, "refresh")
      vim.wait(200)

      assert.are.equal(2, #event_handlers, "must reattach the subscription")
    end)

    it("does not reattach the subscription when it is alive", function()
      local handle = open_view()

      lifecycle.dispatch_for_test(handle, "refresh")
      vim.wait(200)

      assert.are.equal(1, #event_handlers)
    end)
  end)

  describe("cleanup when the view is destroyed", function()
    it("stops the subscription job when closed with q", function()
      local handle = open_view()
      -- close detaches the subscription from the handle, so hold on to it beforehand.
      local subscription = assert(handle.subscription)
      assert.is_true(subscription.is_alive())

      lifecycle.dispatch_for_test(handle, "close")

      assert.is_false(subscription.is_alive())
    end)

    it("removes the subscription job from the ledger when closed", function()
      open_view()
      assert.are.equal(1, #jobs.list())

      lifecycle.close("container")

      assert.are.same({}, jobs.list())
    end)

    it("stops the subscription job on close_all as well", function()
      local handle = open_view()
      local subscription = assert(handle.subscription)

      lifecycle.close_all()

      assert.is_false(subscription.is_alive())
      assert.are.same({}, jobs.list())
    end)

    it("does not redraw for an event that arrives after closing", function()
      local handle = open_view()
      local handlers = event_handlers[1]
      lifecycle.close("container")

      handlers.on_stdout(vim.json.encode({
        Type = "container",
        Action = "start",
        Actor = { ID = "id1" },
        time = 1,
      }) .. "\n")
      vim.wait(200)

      assert.is_false(vim.api.nvim_buf_is_valid(handle.window.bufnr))
    end)
  end)

  describe("store updates driven by events", function()
    it("removes the item from the list on a destroy event", function()
      local handle = open_view()

      event_handlers[1].on_stdout(vim.json.encode({
        Type = "container",
        Action = "destroy",
        Actor = { ID = "id2" },
        time = 1,
      }) .. "\n")
      assert(vim.wait(2000, function()
        return #vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false) == 2
      end))

      local names = table.concat(vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false), " ")
      assert.is_nil(names:find("c2", 1, true), names)
    end)

    it("refetches only the single target on a start event", function()
      open_view()
      local before = #runs

      event_handlers[1].on_stdout(vim.json.encode({
        Type = "container",
        Action = "start",
        Actor = { ID = "id1" },
        time = 1,
      }) .. "\n")
      vim.wait(500)

      local filtered = 0
      for i = before + 1, #runs do
        if vim.tbl_contains(runs[i], "--filter") then
          filtered = filtered + 1
        end
      end
      assert.are.equal(1, filtered, "must refetch exactly one item")
    end)

    it("does not notify when the fetch of an already gone target fails", function()
      open_view()
      cli._set_executor(function(cmd, _, on_exit)
        table.insert(runs, cmd)
        on_exit({ code = 0, stdout = "", stderr = "" })
      end)
      local before = #notified

      event_handlers[1].on_stdout(vim.json.encode({
        Type = "container",
        Action = "die",
        Actor = { ID = "gone" },
        time = 1,
      }) .. "\n")
      vim.wait(500)

      assert.are.equal(before, #notified, "must not notify the user")
    end)

    it("does not refetch for an event of another kind", function()
      open_view()
      local before = #runs

      event_handlers[1].on_stdout(vim.json.encode({
        Type = "volume",
        Action = "create",
        Actor = { ID = "vol" },
        time = 1,
      }) .. "\n")
      vim.wait(300)

      assert.are.equal(before, #runs)
    end)
  end)
end)
