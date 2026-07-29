local cli = require("docker.adapters.docker.cli")
local config = require("docker.config")
local events = require("docker.adapters.docker.events")
local jobs = require("docker.handlers.jobs")
local lifecycle = require("docker.handlers.lifecycle")
local store = require("docker.state.store")

describe("手動再取得とビューの後始末", function()
  local runs
  local original_notify
  local notified
  local event_handlers
  local subscriptions

  --- コンテナ n 件ぶんの NDJSON を返す偽の docker。
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
    it("一覧を取り直す", function()
      local handle = open_view()
      local before = list_fetch_count()

      lifecycle.dispatch_for_test(handle, "refresh")
      vim.wait(200)

      assert.are.equal(before + 1, list_fetch_count())
    end)

    it("取り直した内容が画面へ反映される", function()
      local handle = open_view()
      assert.are.equal(3, #vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false))

      stub_docker(5)
      lifecycle.dispatch_for_test(handle, "refresh")
      vim.wait(200)

      assert.are.equal(5, #vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false))
    end)

    it("取り直してもカーソル位置が保たれる", function()
      local handle = open_view()
      vim.api.nvim_win_set_cursor(handle.window.winid, { 3, 0 })

      lifecycle.dispatch_for_test(handle, "refresh")
      vim.wait(200)

      assert.are.equal(3, vim.api.nvim_win_get_cursor(handle.window.winid)[1])
    end)

    it("購読が止まっていれば再開する", function()
      -- G10: R は一覧の取り直しに加えて、切れた購読を戻す。
      local handle = open_view()
      assert.are.equal(1, #event_handlers)
      assert(handle.subscription).stop()

      lifecycle.dispatch_for_test(handle, "refresh")
      vim.wait(200)

      assert.are.equal(2, #event_handlers, "購読を張り直すこと")
    end)

    it("購読が生きていれば張り直さない", function()
      local handle = open_view()

      lifecycle.dispatch_for_test(handle, "refresh")
      vim.wait(200)

      assert.are.equal(1, #event_handlers)
    end)
  end)

  describe("ビュー破棄時の後始末", function()
    it("qで閉じると購読ジョブが止まる", function()
      local handle = open_view()
      -- close は handle から購読を外すので、先に控えておく。
      local subscription = assert(handle.subscription)
      assert.is_true(subscription.is_alive())

      lifecycle.dispatch_for_test(handle, "close")

      assert.is_false(subscription.is_alive())
    end)

    it("閉じると購読ジョブが台帳から外れる", function()
      open_view()
      assert.are.equal(1, #jobs.list())

      lifecycle.close("container")

      assert.are.same({}, jobs.list())
    end)

    it("close_allでも購読ジョブが止まる", function()
      local handle = open_view()
      local subscription = assert(handle.subscription)

      lifecycle.close_all()

      assert.is_false(subscription.is_alive())
      assert.are.same({}, jobs.list())
    end)

    it("閉じた後に届いたイベントで再描画しない", function()
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

  describe("イベントによるストア更新", function()
    it("削除のイベントで一覧から取り除く", function()
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

    it("開始のイベントでは対象1件だけを取り直す", function()
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
      assert.are.equal(1, filtered, "1 件だけ取り直すこと")
    end)

    it("既に消えた対象の取得失敗は通知しない", function()
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

      assert.are.equal(before, #notified, "利用者へ通知しないこと")
    end)

    it("他の種別のイベントでは取り直さない", function()
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
