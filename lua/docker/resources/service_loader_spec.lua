local cli = require("docker.adapters.docker.cli")
local service_loader = require("docker.resources.service_loader")

describe("docker.resources.service_loader", function()
  local runs

  --- One row of the container list (the parsed data of ps).
  ---@param overrides table|nil
  ---@return table
  local function container(overrides)
    return vim.tbl_extend("force", {
      id = "abc123",
      name = "shop-web-1",
      image = "alpine",
      state = "running",
      status = "Up 5 days",
      ports = "",
      command = '"sleep"',
      created_at = "now",
      compose_project = "shop",
      compose_service = "web",
      compose_oneoff = "False",
      compose_working_dir = "/work/shop",
    }, overrides or {})
  end

  ---@param items table[]
  ---@return string
  local function ndjson(items)
    local lines = {}
    for _, item in ipairs(items) do
      table.insert(lines, vim.json.encode(item))
    end
    return table.concat(lines, "\n")
  end

  --- The name that tells the kind of a command. Used to select the response and to order the replies.
  ---@param cmd string[]
  ---@return "ps"|"ls"|"config"|"cwd_config"
  local function kind_of(cmd)
    if cmd[2] == "ps" then
      return "ps"
    end
    if cmd[3] == "ls" then
      return "ls"
    end
    if cmd[3] == "-p" then
      return "config"
    end
    return "cwd_config"
  end

  ---@param responses table
  ---@param cmd string[]
  ---@return table
  local function response_for(responses, cmd)
    local kind = kind_of(cmd)
    if kind == "ps" then
      return responses.ps or { code = 0, stdout = "" }
    end
    if kind == "ls" then
      return responses.ls or { code = 0, stdout = "[]" }
    end
    if kind == "config" then
      local per_project = responses.config or {}
      return per_project[cmd[4]] or { code = 1, stderr = "no configuration file provided: not found" }
    end
    return responses.cwd_config or { code = 1, stderr = "no configuration file provided: not found" }
  end

  --- A fake docker that varies the response by the kind of command.
  --- responses:
  ---   ls        : { code, stdout } — `compose ls -a`
  ---   ps        : { code, stdout } — the container list
  ---   cwd_config: { code, stdout, stderr } — `compose config` (without a project name)
  ---   config    : table<string, { code, stdout, stderr }> — `compose -p <name> config`
  local function stub(responses)
    cli._set_executor(function(cmd, opts, on_exit)
      table.insert(runs, { cmd = cmd, opts = opts })
      local out = response_for(responses, cmd)
      on_exit({ code = out.code or 0, stdout = out.stdout or "", stderr = out.stderr or "" })
    end)
  end

  --- A fake docker that holds the responses back and can reply in any order.
  --- The order in which docker replies is not necessarily the order the commands were issued in,
  --- so this checks that changing the order does not change the result.
  ---@param responses table
  ---@return { flush: fun(kind: string), pending: fun(): string[] }
  local function deferred_stub(responses)
    local queue = {}
    cli._set_executor(function(cmd, opts, on_exit)
      table.insert(runs, { cmd = cmd, opts = opts })
      table.insert(queue, {
        kind = kind_of(cmd),
        deliver = function()
          local out = response_for(responses, cmd)
          on_exit({ code = out.code or 0, stdout = out.stdout or "", stderr = out.stderr or "" })
        end,
      })
    end)

    return {
      --- Replies with one held-back response of the given kind.
      flush = function(kind)
        for index, entry in ipairs(queue) do
          if entry.kind == kind then
            table.remove(queue, index)
            entry.deliver()
            return
          end
        end
        error("no held-back response of this kind: " .. kind)
      end,
      pending = function()
        local kinds = {}
        for _, entry in ipairs(queue) do
          table.insert(kinds, entry.kind)
        end
        return kinds
      end,
    }
  end

  ---@param responses table
  ---@param cwd string|nil
  ---@return docker.ServiceLoadResult
  local function load(responses, cwd)
    stub(responses)
    local captured, calls = nil, 0
    service_loader.load({
      cwd = cwd or "/elsewhere",
      container_args = { "ps", "-a", "--format", "{{json .}}" },
    }, function(result)
      captured, calls = result, calls + 1
    end)
    -- With multi-stage asynchrony, the way it breaks is that completion runs twice depending on the path.
    assert.are.equal(1, calls)
    return assert(captured, "on_done was not called")
  end

  ---@param items docker.Service[]
  ---@return string[]
  local function keys_of(items)
    local keys = {}
    for _, item in ipairs(items) do
      table.insert(keys, ("%s/%s=%s"):format(item.project, item.name, item.status))
    end
    return keys
  end

  before_each(function()
    runs = {}
  end)

  after_each(function()
    cli._set_executor(nil)
  end)

  describe("listing from a place with no compose file", function()
    it("lists the services of the projects derived from the labels", function()
      -- Even when the compose file cannot be read, the services can be derived from the container labels.
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop","Status":"exited(1)","ConfigFiles":"/work/shop/compose.yaml"}]' },
        ps = { code = 0, stdout = ndjson({ container({ state = "exited" }) }) },
        config = {
          shop = { code = 0, stdout = '{"name":"shop","services":{"web":{},"never-started":{}}}' },
        },
      })

      assert.is_true(result.ok)
      assert.are.same({
        {
          project = "shop",
          name = "never-started",
          container = "",
          container_id = "",
          status = "none",
          working_dir = "/work/shop",
        },
        {
          project = "shop",
          name = "web",
          container = "shop-web-1",
          container_id = "abc123",
          status = "exited",
          working_dir = "/work/shop",
        },
      }, result.data)
    end)

    it("carries the location of the compose file on every row", function()
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop","ConfigFiles":"/work/shop/compose.yaml"}]' },
        ps = { code = 0, stdout = ndjson({ container() }) },
        config = { shop = { code = 0, stdout = '{"name":"shop","services":{"web":{}}}' } },
      })

      assert.are.equal("/work/shop", result.data[1].working_dir)
    end)

    it("looks up the project definitions at the location found in the container labels", function()
      load({
        ls = { code = 0, stdout = '[{"Name":"shop","ConfigFiles":"/other/compose.yaml"}]' },
        ps = { code = 0, stdout = ndjson({ container({ compose_working_dir = "/work/shop" }) }) },
        config = { shop = { code = 0, stdout = '{"name":"shop","services":{"web":{}}}' } },
      })

      local config_run
      for _, run in ipairs(runs) do
        if run.cmd[3] == "-p" then
          config_run = run
        end
      end
      assert.are.same({ "docker", "compose", "-p", "shop", "config", "--format", "json" }, config_run.cmd)
      assert.are.equal("/work/shop", config_run.opts.cwd)
    end)

    it("picks up the location even when the same project has containers that do not carry it", function()
      -- Containers created by an older compose have no label. Do not give up on the first one.
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop"}]' },
        ps = {
          code = 0,
          stdout = ndjson({
            container({ id = "old", name = "shop-web-1", compose_working_dir = "" }),
            container({ id = "new", name = "shop-web-2", compose_working_dir = "/work/shop" }),
          }),
        },
        config = { shop = { code = 0, stdout = '{"name":"shop","services":{"web":{}}}' } },
      })

      assert.are.equal("/work/shop", result.data[1].working_dir)
    end)

    it("decides the location from the config file path when the label does not carry it", function()
      -- The fallback for an older compose that has no working_dir label.
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop","ConfigFiles":"/work/shop/compose.yaml"}]' },
        ps = { code = 0, stdout = ndjson({ container({ compose_working_dir = "" }) }) },
        config = { shop = { code = 0, stdout = '{"name":"shop","services":{"web":{}}}' } },
      })

      assert.are.equal("/work/shop", result.data[1].working_dir)
    end)

    it("uses the location of the first one when there are several config files", function()
      local result = load({
        ls = {
          code = 0,
          stdout = '[{"Name":"shop","ConfigFiles":"/work/shop/compose.yaml,/work/shop/compose.override.yaml"}]',
        },
        ps = { code = 0, stdout = ndjson({ container({ compose_working_dir = "" }) }) },
        config = { shop = { code = 0, stdout = '{"name":"shop","services":{"web":{}}}' } },
      })

      assert.are.equal("/work/shop", result.data[1].working_dir)
    end)
  end)

  describe("merging several projects", function()
    it("lists the services of every project together", function()
      local result = load({
        ls = {
          code = 0,
          stdout = '[{"Name":"shop","ConfigFiles":"/work/shop/compose.yaml"},'
            .. '{"Name":"blog","ConfigFiles":"/work/blog/compose.yaml"}]',
        },
        ps = {
          code = 0,
          stdout = ndjson({
            container(),
            container({
              id = "b1",
              name = "blog-cms-1",
              compose_project = "blog",
              compose_service = "cms",
              compose_working_dir = "/work/blog",
            }),
          }),
        },
        config = {
          shop = { code = 0, stdout = '{"name":"shop","services":{"web":{}}}' },
          blog = { code = 0, stdout = '{"name":"blog","services":{"cms":{}}}' },
        },
      })

      assert.are.same({ "blog/cms=running", "shop/web=running" }, keys_of(result.data))
    end)

    it("merges in the project of the working directory", function()
      -- A project that has never been started does not appear in the labels, so it can only be
      -- picked up here.
      local result = load({
        ls = { code = 0, stdout = "[]" },
        ps = { code = 0, stdout = "" },
        cwd_config = { code = 0, stdout = '{"name":"fresh","services":{"web":{},"db":{}}}' },
      }, "/work/fresh")

      assert.is_true(result.ok)
      assert.are.same({ "fresh/db=none", "fresh/web=none" }, keys_of(result.data))
      assert.are.equal("/work/fresh", result.data[1].working_dir)
    end)

    it("does not list twice when the project of the working directory is also in the labels", function()
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop","ConfigFiles":"/work/shop/compose.yaml"}]' },
        ps = { code = 0, stdout = ndjson({ container() }) },
        cwd_config = { code = 0, stdout = '{"name":"shop","services":{"web":{},"never-started":{}}}' },
      }, "/work/shop")

      assert.are.same({ "shop/never-started=none", "shop/web=running" }, keys_of(result.data))
    end)

    it("prefers the location of the project opened in the working directory over the label", function()
      -- The project was moved elsewhere and not started yet. The label still points at the old
      -- location, so unless the current location is taken, the start would run on an old definition.
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop","ConfigFiles":"/work/shop/compose.yaml"}]' },
        ps = { code = 0, stdout = ndjson({ container({ compose_working_dir = "/work/shop" }) }) },
        cwd_config = { code = 0, stdout = '{"name":"shop","services":{"web":{}}}' },
      }, "/work/shop-moved")

      assert.are.equal("/work/shop-moved", result.data[1].working_dir)
    end)

    it("returns the list even when the working directory is outside any project", function()
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop","ConfigFiles":"/work/shop/compose.yaml"}]' },
        ps = { code = 0, stdout = ndjson({ container() }) },
        cwd_config = { code = 1, stderr = "no configuration file provided: not found" },
        config = { shop = { code = 0, stdout = '{"name":"shop","services":{"web":{}}}' } },
      })

      assert.is_true(result.ok)
      assert.is_nil(result.warning)
      assert.are.same({ "shop/web=running" }, keys_of(result.data))
    end)

    it("returns an empty list when there is not a single project", function()
      local result = load({ ls = { code = 0, stdout = "[]" }, ps = { code = 0, stdout = "" } })

      assert.is_true(result.ok)
      assert.are.same({}, result.data)
    end)
  end)

  describe("the order the responses arrive in", function()
    local RESPONSES = {
      ls = { code = 0, stdout = '[{"Name":"shop","ConfigFiles":"/work/shop/compose.yaml"}]' },
      ps = { code = 0, stdout = ndjson({ container() }) },
      cwd_config = { code = 1, stderr = "no configuration file provided: not found" },
      config = { shop = { code = 0, stdout = '{"name":"shop","services":{"web":{},"never-started":{}}}' } },
    }

    --- Replies in the given order and obtains the assembled list.
    ---@param order string[] the kinds arranged in the order they reply ("ls" / "ps" / "cwd_config")
    ---@return docker.ServiceLoadResult
    ---@return string[] the record that it had not completed yet at the point before the last one replied
    local function load_in_order(order)
      local stubbed = deferred_stub(RESPONSES)
      local captured
      service_loader.load({
        cwd = "/elsewhere",
        container_args = { "ps", "-a", "--format", "{{json .}}" },
      }, function(result)
        captured = result
      end)

      local seen_before_last = {}
      for index, kind in ipairs(order) do
        if index == #order then
          seen_before_last = keys_of(captured and captured.data or {})
        end
        stubbed.flush(kind)
      end
      -- Fetching the definitions is only issued once the responses so far are in. Reply to the rest.
      while #stubbed.pending() > 0 do
        stubbed.flush(stubbed.pending()[1])
      end

      return assert(captured, "on_done was not called"), seen_before_last
    end

    it("does not assemble the list until the last one has replied", function()
      -- Assembling before they are all in would treat the container list that is not fetched yet
      -- as 0 items.
      local result, before_last = load_in_order({ "ls", "cwd_config", "ps" })

      assert.are.same({}, before_last)
      assert.are.same({ "shop/never-started=none", "shop/web=running" }, keys_of(result.data))
    end)

    it("builds the same list regardless of the order the responses arrive in", function()
      local forward = load_in_order({ "ls", "ps", "cwd_config" })
      local reversed = load_in_order({ "cwd_config", "ps", "ls" })

      assert.are.same(forward.data, reversed.data)
      assert.are.same({ "shop/never-started=none", "shop/web=running" }, keys_of(reversed.data))
    end)
  end)

  describe("projects whose definitions cannot be looked up", function()
    it("lists only the services that have a container when the compose file cannot be read", function()
      -- A project whose working_dir is gone. The services that are not started cannot be known.
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop","ConfigFiles":"/gone/compose.yaml"}]' },
        ps = { code = 0, stdout = ndjson({ container({ compose_working_dir = "/gone" }) }) },
        config = { shop = { code = 1, stderr = "no configuration file provided: not found" } },
      })

      assert.is_true(result.ok)
      assert.are.same({ "shop/web=running" }, keys_of(result.data))
    end)

    it("does not go and look up the definitions for a project whose location is unknown", function()
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop"}]' },
        ps = { code = 0, stdout = ndjson({ container({ compose_working_dir = "" }) }) },
      })

      local issued = {}
      for _, run in ipairs(runs) do
        table.insert(issued, table.concat(run.cmd, " "))
      end
      table.sort(issued)
      assert.are.same({
        "docker compose config --format json",
        "docker compose ls -a --format json",
        "docker ps -a --format {{json .}}",
      }, issued)
      assert.are.same({ "shop/web=running" }, keys_of(result.data))
      assert.are.equal("", result.data[1].working_dir)
    end)

    it("gives a project that only has one-off containers no services", function()
      -- BR-006: a container of `docker compose run` is not the instance of a service.
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop"}]' },
        ps = {
          code = 0,
          stdout = ndjson({
            container({ name = "shop-web-run-abc", compose_oneoff = "True", compose_working_dir = "" }),
          }),
        },
      })

      assert.is_true(result.ok)
      assert.are.same({}, result.data)
    end)
  end)

  describe("handling of failures", function()
    it("does not return a list when the compose subcommand is unavailable", function()
      local result = load({
        ls = { code = 1, stderr = "docker: unknown command: docker compose" },
        ps = { code = 0, stdout = "" },
      })

      assert.is_false(result.ok)
      assert.are.equal(
        "docker compose サブコマンドが使えません。compose プラグインの導入を確認してください。",
        result.error
      )
    end)

    it("does not return a list when fetching the container list fails", function()
      local result = load({
        ls = { code = 0, stdout = "[]" },
        ps = { code = 1, stderr = "Cannot connect to the Docker daemon" },
      })

      assert.is_false(result.ok)
      assert.are.equal("Cannot connect to the Docker daemon", result.error)
    end)

    it("returns the list with a warning attached when the compose file of the working directory is invalid", function()
      -- The other projects are visible so the list itself is shown (BR-016: the wording is passed through).
      local stderr = "yaml: mapping values are not allowed in this context"
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop","ConfigFiles":"/work/shop/compose.yaml"}]' },
        ps = { code = 0, stdout = ndjson({ container() }) },
        cwd_config = { code = 1, stderr = stderr },
        config = { shop = { code = 0, stdout = '{"name":"shop","services":{"web":{}}}' } },
      })

      assert.is_true(result.ok)
      assert.are.equal(stderr, result.warning)
      assert.are.same({ "shop/web=running" }, keys_of(result.data))
    end)
  end)
end)
