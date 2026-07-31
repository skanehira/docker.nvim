local cli = require("docker.adapters.docker.cli")
local config = require("docker.config")
local events = require("docker.adapters.docker.events")
local jobs = require("docker.handlers.jobs")
local lifecycle = require("docker.handlers.lifecycle")
local store = require("docker.state.store")

describe("the compose service list view", function()
  local notified, event_handlers
  local original_notify

  --- A fake docker that answers project enumeration, the container list and the compose definition.
  ---@param opts { projects: table<string, string[]>|nil, containers: table[]|nil,
  ---             cwd_project: string|nil, cwd_stderr: string|nil, compose_stderr: string|nil }
  local function stub(opts)
    --- project name -> list of service names. The default is a shop project with only web in it.
    local projects = opts.projects or { shop = { "web" } }

    cli._set_executor(function(cmd, _, on_exit)
      if cmd[2] == "version" then
        on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
        return
      end

      if cmd[2] == "compose" then
        -- When the compose subcommand itself is unavailable, every compose call fails the same way.
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

        -- Fetching the definition. The presence of `-p` decides whether the project is named
        -- explicitly or derived from the working directory.
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

  describe("opening", function()
    it("lists the services together with the containers they are tied to", function()
      stub({ projects = { shop = { "web", "never-started" } }, containers = { container() } })

      local handle = assert(open_services())

      -- A service that is not running has an empty CONTAINER column, so no trailing
      -- whitespace is left at the end of the line.
      assert.are.same({
        "shop     never-started  none",
        "shop     web            running  shop-web-1",
      }, vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false))
    end)

    it("orders the headers as PROJECT, SERVICE, STATUS, CONTAINER", function()
      stub({ containers = { container() } })

      local handle = assert(open_services())

      -- The winbar has highlight specifiers mixed in, so pull out only the header words in order.
      local headers = {}
      for word in vim.wo[handle.window.winid].winbar:gmatch("%u%u+") do
        table.insert(headers, word)
      end
      assert.are.same({ "PROJECT", "SERVICE", "STATUS", "CONTAINER" }, headers)
    end)

    it("shows none as the status of a service that is not running", function()
      -- BR-005
      stub({ projects = { shop = { "never-started" } }, containers = {} })

      local handle = assert(open_services())

      assert.are.same({ "shop     never-started  none" }, vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false))
    end)

    it("lists every project even outside a compose project", function()
      -- Even with no compose file in the working directory, the projects can be worked out
      -- backwards from the containers' labels.
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

    it("opens an empty list when there is not a single compose project", function()
      stub({ projects = {}, containers = {} })
      local windows_before = #vim.api.nvim_list_wins()

      local handle = assert(open_services())

      assert.are.same(
        { "compose プロジェクトがありません" },
        vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false)
      )
      assert.are.equal(windows_before + 1, #vim.api.nvim_list_wins())
    end)

    it("does not open the view when the compose subcommand is unavailable", function()
      stub({ compose_stderr = "docker: unknown command: docker compose" })
      local windows_before = #vim.api.nvim_list_wins()

      assert.is_nil(open_services())
      assert.is_nil(lifecycle.get("service"))
      assert.are.equal(windows_before, #vim.api.nvim_list_wins(), "no extra window should be created")
      assert.are.equal(
        "docker compose サブコマンドが使えません。compose プラグインの導入を確認してください。",
        notified[#notified].msg
      )
    end)

    it(
      "opens the list and reports the output as-is even when the working directory's compose file is invalid",
      function()
        -- The other projects are still visible, so the list itself is shown.
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

  describe("live updates", function()
    it("changes the status of a service on a container event", function()
      stub({ containers = { container({ state = "running" }) } })
      local handle = assert(open_services())
      assert.is_truthy(vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, 1, false)[1]:find("running", 1, true))

      -- Make the re-fetch return the container in a stopped state before emitting the event
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
        "the service status should be updated"
      )
    end)

    it("returns the service to none when its container disappears", function()
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

    it("does not repeat the same warning on every event", function()
      -- The list is re-fetched on every container event. While the compose file in the working
      -- directory stays broken, the same text would pile up on each refresh.
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

    it("reports the warning again once its content changes", function()
      -- If the suppression were "notify only the first time", a change in how the compose file
      -- is broken would go unnoticed.
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
