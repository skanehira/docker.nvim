local cli = require("docker.adapters.docker.cli")
local config = require("docker.config")
local events = require("docker.adapters.docker.events")
local jobs = require("docker.handlers.jobs")
local lifecycle = require("docker.handlers.lifecycle")
local store = require("docker.state.store")

describe("compose サービス一覧のビュー", function()
  local notified, event_handlers
  local original_notify

  --- プロジェクトの列挙・コンテナ一覧・compose の定義に応える偽の docker。
  ---@param opts { projects: table<string, string[]>|nil, containers: table[]|nil,
  ---             cwd_project: string|nil, cwd_stderr: string|nil, compose_stderr: string|nil }
  local function stub(opts)
    --- プロジェクト名 -> サービス名の一覧。既定は shop に web だけがある状態。
    local projects = opts.projects or { shop = { "web" } }

    cli._set_executor(function(cmd, _, on_exit)
      if cmd[2] == "version" then
        on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
        return
      end

      if cmd[2] == "compose" then
        -- compose サブコマンド自体が使えない状況は、どの compose 呼び出しでも同じ失敗になる。
        if opts.compose_stderr then
          on_exit({ code = 1, stdout = "", stderr = opts.compose_stderr })
          return
        end

        if cmd[3] == "ls" then
          local listings = {}
          for name in pairs(projects) do
            table.insert(listings, { Name = name, ConfigFiles = ("/work/%s/compose.yaml"):format(name) })
          end
          table.sort(listings, function(a, b)
            return a.Name < b.Name
          end)
          on_exit({ code = 0, stderr = "", stdout = vim.json.encode(listings) })
          return
        end

        -- 定義の取得。`-p` の有無で、名指しか作業ディレクトリ由来かが決まる。
        local name = cmd[3] == "-p" and cmd[4] or opts.cwd_project
        if not name then
          on_exit({ code = 1, stdout = "", stderr = opts.cwd_stderr or "no configuration file provided: not found" })
          return
        end
        local services = {}
        for _, service in ipairs(projects[name] or {}) do
          services[service] = vim.empty_dict()
        end
        on_exit({ code = 0, stderr = "", stdout = vim.json.encode({ name = name, services = services }) })
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
      compose_working_dir = "/work/shop",
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
      stub({ projects = { shop = { "web", "never-started" } }, containers = { container() } })

      local handle = assert(open_services())

      -- 起動していないサービスは CONTAINER 列が空なので、行末の余白は残らない。
      assert.are.same({
        "shop     never-started  none",
        "shop     web            running  shop-web-1",
      }, vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false))
    end)

    it("見出しはPROJECT_SERVICE_STATUS_CONTAINERの順に並ぶ", function()
      stub({ containers = { container() } })

      local handle = assert(open_services())

      -- winbar にはハイライトの指定が混ざるので、見出しの語だけを順に取り出して見る。
      local headers = {}
      for word in vim.wo[handle.window.winid].winbar:gmatch("%u%u+") do
        table.insert(headers, word)
      end
      assert.are.same({ "PROJECT", "SERVICE", "STATUS", "CONTAINER" }, headers)
    end)

    it("起動していないサービスは状態がnoneになる", function()
      -- BR-005
      stub({ projects = { shop = { "never-started" } }, containers = {} })

      local handle = assert(open_services())

      assert.are.same({ "shop     never-started  none" }, vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false))
    end)

    it("composeプロジェクト外でも全プロジェクトの一覧を出す", function()
      -- 作業ディレクトリに compose ファイルが無くても、コンテナのラベルから逆算できる。
      stub({
        projects = { shop = { "web" }, blog = { "cms" } },
        containers = {
          container(),
          container({
            id = "b1",
            name = "blog-cms-1",
            compose_project = "blog",
            compose_service = "cms",
            compose_working_dir = "/work/blog",
          }),
        },
      })

      local handle = assert(open_services())

      assert.are.same({
        "blog     cms      running  blog-cms-1",
        "shop     web      running  shop-web-1",
      }, vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false))
    end)

    it("compose プロジェクトが1つも無いときは空の一覧を開く", function()
      stub({ projects = {}, containers = {} })
      local windows_before = #vim.api.nvim_list_wins()

      local handle = assert(open_services())

      assert.are.same(
        { "compose プロジェクトがありません" },
        vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false)
      )
      assert.are.equal(windows_before + 1, #vim.api.nvim_list_wins())
    end)

    it("composeサブコマンドが無いときはビューを開かない", function()
      stub({ compose_stderr = "docker: unknown command: docker compose" })
      local windows_before = #vim.api.nvim_list_wins()

      assert.is_nil(open_services())
      assert.is_nil(lifecycle.get("service"))
      assert.are.equal(windows_before, #vim.api.nvim_list_wins(), "ウィンドウを増やさないこと")
      assert.are.equal(
        "docker compose サブコマンドが使えません。compose プラグインの導入を確認してください。",
        notified[#notified].msg
      )
    end)

    it(
      "作業ディレクトリのcomposeファイルが不正でも一覧を開いて出力をそのまま伝える",
      function()
        -- 他のプロジェクトは見えるので、一覧そのものは出す。
        stub({
          containers = { container() },
          cwd_stderr = "yaml: mapping values are not allowed in this context",
        })

        local handle = assert(open_services())

        assert.are.same(
          { "shop     web      running  shop-web-1" },
          vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false)
        )
        assert.are.equal("yaml: mapping values are not allowed in this context", notified[#notified].msg)
      end
    )
  end)

  describe("ライブ更新", function()
    it("コンテナのイベントでサービスの状態が変わる", function()
      stub({ containers = { container({ state = "running" }) } })
      local handle = assert(open_services())
      assert.is_truthy(vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, 1, false)[1]:find("running", 1, true))

      -- コンテナが停止した状態で再取得されるようにしてからイベントを流す
      stub({ containers = { container({ state = "exited" }) } })
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
      stub({ containers = { container() } })
      local handle = assert(open_services())

      stub({ containers = {} })
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

    it("同じ警告をイベントのたびに繰り返さない", function()
      -- 一覧はコンテナのイベントごとに取り直す。作業ディレクトリの compose ファイルが
      -- 壊れたままだと、更新のたびに同じ文言が積み上がる。
      local stderr = "yaml: mapping values are not allowed in this context"
      stub({ containers = { container({ state = "running" }) }, cwd_stderr = stderr })
      local handle = assert(open_services())
      assert.are.equal(stderr, notified[#notified].msg)
      local notified_before = #notified

      stub({ containers = { container({ state = "exited" }) }, cwd_stderr = stderr })
      event_handlers[1].on_stdout(vim.json.encode({
        Type = "container",
        Action = "die",
        Actor = { ID = "abc123" },
        time = 1,
      }) .. "\n")
      assert(vim.wait(2000, function()
        return vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, 1, false)[1]:find("exited", 1, true) ~= nil
      end))

      assert.are.equal(notified_before, #notified)
    end)

    it("警告の内容が変わったら伝え直す", function()
      -- 抑止を「初回だけ通知」にすると、compose ファイルの壊れ方が変わっても気付けない。
      local first = "yaml: mapping values are not allowed in this context"
      local second = "yaml: did not find expected key"
      stub({ containers = { container({ state = "running" }) }, cwd_stderr = first })
      local handle = assert(open_services())
      assert.are.equal(first, notified[#notified].msg)

      stub({ containers = { container({ state = "exited" }) }, cwd_stderr = second })
      event_handlers[1].on_stdout(vim.json.encode({
        Type = "container",
        Action = "die",
        Actor = { ID = "abc123" },
        time = 1,
      }) .. "\n")
      assert(vim.wait(2000, function()
        return vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, 1, false)[1]:find("exited", 1, true) ~= nil
      end))

      assert.are.equal(second, notified[#notified].msg)
    end)
  end)
end)
