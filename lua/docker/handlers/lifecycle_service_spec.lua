local cli = require("docker.adapters.docker.cli")
local config = require("docker.config")
local events = require("docker.adapters.docker.events")
local jobs = require("docker.handlers.jobs")
local lifecycle = require("docker.handlers.lifecycle")
local store = require("docker.state.store")

describe("compose サービス一覧のビュー", function()
  local notified, event_handlers
  local original_notify

  --- compose の解決とコンテナ一覧の両方に応える偽の docker。
  ---@param opts { compose_stderr: string|nil, services: string[]|nil, containers: table[]|nil }
  local function stub(opts)
    cli._set_executor(function(cmd, _, on_exit)
      if cmd[2] == "version" then
        on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
        return
      end
      if cmd[2] == "compose" then
        if opts.compose_stderr then
          on_exit({ code = 1, stdout = "", stderr = opts.compose_stderr })
          return
        end
        local services = {}
        for _, name in ipairs(opts.services or { "web" }) do
          services[name] = vim.empty_dict()
        end
        on_exit({
          code = 0,
          stderr = "",
          stdout = vim.json.encode({ name = "shop", services = services }),
        })
        return
      end
      local rows = {}
      for _, c in ipairs(opts.containers or {}) do
        table.insert(rows, vim.json.encode(c))
      end
      on_exit({ code = 0, stdout = table.concat(rows, "\n"), stderr = "" })
    end)
  end

  ---@param overrides table|nil
  local function container(overrides)
    return vim.tbl_extend("force", {
      id = "abc123",
      name = "shop-web-1",
      image = "alpine",
      state = "running",
      status = "Up",
      ports = "",
      command = "x",
      created_at = "now",
      compose_project = "shop",
      compose_service = "web",
      compose_oneoff = "False",
    }, overrides or {})
  end

  ---@return docker.ViewHandle|nil
  local function open_services()
    local captured, called = nil, false
    lifecycle.open("service", function(handle)
      captured, called = handle, true
    end)
    assert(vim.wait(3000, function()
      return called
    end))
    return captured
  end

  before_each(function()
    notified, event_handlers = {}, {}
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
    events._set_starter(function(_, handlers)
      table.insert(event_handlers, handlers)
      return 900 + #event_handlers
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

  describe("開く", function()
    it("サービスと紐付くコンテナを一覧に出す", function()
      stub({ services = { "web", "never-started" }, containers = { container() } })

      local handle = assert(open_services())

      -- 起動していないサービスは CONTAINER 列が空なので、行末の余白は残らない。
      assert.are.same({
        "never-started  none",
        "web            running  shop-web-1",
      }, vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false))
    end)

    it("見出しはSERVICE_STATUS_CONTAINERになる", function()
      stub({ services = { "web" }, containers = { container() } })

      local handle = assert(open_services())

      local winbar = vim.wo[handle.window.winid].winbar
      assert.is_truthy(winbar:find("SERVICE", 1, true), winbar)
      assert.is_truthy(winbar:find("CONTAINER", 1, true), winbar)
    end)

    it("起動していないサービスは状態がnoneになる", function()
      -- BR-005
      stub({ services = { "never-started" }, containers = {} })

      local handle = assert(open_services())

      assert.is_truthy(vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, 1, false)[1]:find("none", 1, true))
    end)

    it("composeプロジェクト外ではビューを開かずメッセージを出す", function()
      -- 7.3: メッセージのみ表示し、空のフロートを残さない。
      stub({ compose_stderr = "no configuration file provided: not found" })
      local windows_before = #vim.api.nvim_list_wins()

      local handle = open_services()

      assert.is_nil(handle)
      assert.is_nil(lifecycle.get("service"))
      assert.are.equal(windows_before, #vim.api.nvim_list_wins(), "ウィンドウを増やさないこと")
      assert.is_truthy(notified[#notified].msg:find("compose", 1, true), notified[#notified].msg)
    end)

    it("composeサブコマンドが無いときもビューを開かない", function()
      stub({ compose_stderr = "docker: unknown command: docker compose" })

      assert.is_nil(open_services())
      assert.is_nil(lifecycle.get("service"))
    end)

    it("composeファイルが不正なときはdockerの出力をそのまま伝える", function()
      stub({ compose_stderr = "yaml: mapping values are not allowed in this context" })

      assert.is_nil(open_services())
      assert.are.equal("yaml: mapping values are not allowed in this context", notified[#notified].msg)
    end)
  end)

  describe("ライブ更新", function()
    it("コンテナのイベントでサービスの状態が変わる", function()
      stub({ services = { "web" }, containers = { container({ state = "running" }) } })
      local handle = assert(open_services())
      assert.is_truthy(vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, 1, false)[1]:find("running", 1, true))

      -- コンテナが停止した状態で再取得されるようにしてからイベントを流す
      stub({ services = { "web" }, containers = { container({ state = "exited" }) } })
      event_handlers[1].on_stdout(vim.json.encode({
        Type = "container",
        Action = "die",
        Actor = { ID = "abc123" },
        time = 1,
      }) .. "\n")

      assert(
        vim.wait(2000, function()
          return vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, 1, false)[1]:find("exited", 1, true) ~= nil
        end),
        "サービスの状態が更新されること"
      )
    end)

    it("コンテナが消えるとサービスがnoneに戻る", function()
      stub({ services = { "web" }, containers = { container() } })
      local handle = assert(open_services())

      stub({ services = { "web" }, containers = {} })
      event_handlers[1].on_stdout(vim.json.encode({
        Type = "container",
        Action = "destroy",
        Actor = { ID = "abc123" },
        time = 1,
      }) .. "\n")

      assert(vim.wait(2000, function()
        return vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, 1, false)[1]:find("none", 1, true) ~= nil
      end))
    end)
  end)
end)
