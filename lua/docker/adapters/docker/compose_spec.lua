local cli = require("docker.adapters.docker.cli")
local compose = require("docker.adapters.docker.compose")

describe("docker.adapters.docker.compose", function()
  local runs

  --- A fake docker that returns the given exit state.
  local function stub(out)
    cli._set_executor(function(cmd, opts, on_exit)
      table.insert(runs, { cmd = cmd, opts = opts })
      on_exit({ code = out.code, stdout = out.stdout or "", stderr = out.stderr or "" })
    end)
  end

  ---@return docker.ComposeResult
  local function resolve(cwd)
    local captured
    compose.resolve_project(cwd or "/proj", function(result)
      captured = result
    end)
    return assert(captured, "on_done was not called")
  end

  before_each(function()
    runs = {}
  end)

  after_each(function()
    cli._set_executor(nil)
  end)

  describe("resolve_project", function()
    it("calls docker compose with arguments that fetch the config as JSON", function()
      -- `config --services` is not used because its output order changes on every run.
      stub({ code = 0, stdout = '{"name":"shop","services":{}}' })

      resolve()

      assert.are.same({ "docker", "compose", "config", "--format", "json" }, runs[1].cmd)
    end)

    it("runs in the working directory as of the moment the view was opened", function()
      -- BR-003: resolving compose depends on the current directory.
      stub({ code = 0, stdout = '{"name":"shop","services":{}}' })

      resolve("/work/shop")

      assert.are.equal("/work/shop", runs[1].opts.cwd)
    end)

    it("extracts the project name and all of its services", function()
      stub({
        code = 0,
        stdout = '{"name":"shop","services":{"web":{},"worker":{},"db":{}},"networks":{}}',
      })

      local result = resolve("/work/shop")

      assert.is_true(result.ok)
      assert.are.equal("shop", result.data.name)
      assert.are.equal("/work/shop", result.data.working_dir)
      assert.are.same({ "db", "web", "worker" }, result.data.service_names)
    end)

    it("returns the service names always in the same order", function()
      -- JSON object key order is not guaranteed. They are sorted so that the row order does not
      -- change on every run.
      stub({ code = 0, stdout = '{"name":"shop","services":{"zeta":{},"alpha":{},"mid":{}}}' })

      assert.are.same({ "alpha", "mid", "zeta" }, resolve().data.service_names)
    end)

    it("returns services that have never been started as well", function()
      stub({ code = 0, stdout = '{"name":"shop","services":{"web":{},"never-started":{}}}' })

      assert.are.same({ "never-started", "web" }, resolve().data.service_names)
    end)

    it("treats 0 services as a success", function()
      stub({ code = 0, stdout = '{"name":"shop","services":{}}' })

      local result = resolve()

      assert.is_true(result.ok)
      assert.are.same({}, result.data.service_names)
    end)
  end)

  describe("distinguishing the three failures", function()
    it("returns a category that tells the caller it is outside a compose project", function()
      -- The wording from a real machine (compose v5.1.2).
      -- Being outside a project is handled as a normal case, so it gets no dedicated guidance.
      stub({ code = 1, stderr = "no configuration file provided: not found" })

      local result = resolve()

      assert.is_false(result.ok)
      assert.are.equal("outside", result.reason)
      assert.are.equal("no configuration file provided: not found", result.error)
    end)

    it("returns a message that tells the user the compose subcommand is unavailable", function()
      -- docker 29 says "unknown command", earlier versions "'compose' is not a docker command".
      local messages = {}
      for _, stderr in ipairs({
        "docker: unknown command: docker compose",
        "docker: 'compose' is not a docker command.",
      }) do
        stub({ code = 1, stderr = stderr })
        local result = resolve()
        assert.are.equal("unavailable", result.reason)
        table.insert(messages, result.error)
      end

      assert.are.same({
        "The docker compose subcommand is unavailable. Check that the compose plugin is installed.",
        "The docker compose subcommand is unavailable. Check that the compose plugin is installed.",
      }, messages)
    end)

    it("returns docker's output as-is when the compose file is invalid", function()
      local stderr = "yaml: while parsing a flow sequence at line 2, column 12: did not find expected ',' or ']'"
      stub({ code = 1, stderr = stderr })

      local result = resolve()

      assert.are.equal("invalid", result.reason)
      assert.are.equal(stderr, result.error)
    end)

    it("gives each of the three failures a different category and wording", function()
      -- G11: a missing compose subcommand must be distinguishable from the others.
      local outcomes = {}
      for _, stderr in ipairs({
        "no configuration file provided: not found",
        "docker: unknown command: docker compose",
        "yaml: mapping values are not allowed in this context",
      }) do
        stub({ code = 1, stderr = stderr })
        local result = resolve()
        table.insert(outcomes, { reason = result.reason, message = result.error })
      end

      -- Not only the category but also the wording the user sees must not be mixed up.
      assert.are.same({
        { reason = "outside", message = "no configuration file provided: not found" },
        {
          reason = "unavailable",
          message = "The docker compose subcommand is unavailable. Check that the compose plugin is installed.",
        },
        { reason = "invalid", message = "yaml: mapping values are not allowed in this context" },
      }, outcomes)
    end)

    it("treats output that cannot be parsed as invalid", function()
      stub({ code = 0, stdout = "not json" })

      assert.are.equal("invalid", resolve().reason)
    end)

    it("returns its own message when docker succeeds but the config carries no services", function()
      stub({ code = 0, stdout = "[]" })

      assert.are.same({
        ok = false,
        data = nil,
        error = "Could not parse the docker compose configuration",
        code = 0,
        reason = "invalid",
      }, resolve())
    end)
  end)

  describe("list_projects", function()
    ---@return docker.ComposeResult
    local function list()
      local captured
      compose.list_projects(function(result)
        captured = result
      end)
      return assert(captured, "on_done was not called")
    end

    it("calls docker compose with arguments that fetch every project including stopped ones as JSON", function()
      -- Without `-a` only running projects are listed and stopped projects disappear from the list.
      stub({ code = 0, stdout = "[]" })

      list()

      assert.are.same({ "docker", "compose", "ls", "-a", "--format", "json" }, runs[1].cmd)
    end)

    it("runs without depending on any working directory", function()
      -- Enumerating projects comes from labels and does not depend on where the compose file is.
      stub({ code = 0, stdout = "[]" })

      list()

      assert.is_nil(runs[1].opts.cwd)
    end)

    it("extracts the project name and the config file path", function()
      stub({
        code = 0,
        stdout = '[{"Name":"shop","Status":"running(2)","ConfigFiles":"/work/shop/compose.yaml"},'
          .. '{"Name":"blog","Status":"exited(1)","ConfigFiles":"/work/blog/compose.yaml"}]',
      })

      local result = list()

      assert.is_true(result.ok)
      assert.are.same({
        { name = "shop", config_files = "/work/shop/compose.yaml" },
        { name = "blog", config_files = "/work/blog/compose.yaml" },
      }, result.data)
    end)

    it("treats 0 projects as a success", function()
      stub({ code = 0, stdout = "[]" })

      local result = list()

      assert.is_true(result.ok)
      assert.are.same({}, result.data)
    end)

    it("uses an empty string for a project that has no config file path", function()
      stub({ code = 0, stdout = '[{"Name":"shop","Status":"running(1)"}]' })

      assert.are.same({ { name = "shop", config_files = "" } }, list().data)
    end)

    it("returns a message that tells the user the compose subcommand is unavailable", function()
      stub({ code = 1, stderr = "docker: unknown command: docker compose" })

      local result = list()

      assert.is_false(result.ok)
      assert.are.equal("unavailable", result.reason)
      assert.are.equal(
        "The docker compose subcommand is unavailable. Check that the compose plugin is installed.",
        result.error
      )
    end)

    it("returns its own message when docker succeeds but prints no project list", function()
      stub({ code = 0, stdout = "" })

      assert.are.same({
        ok = false,
        data = nil,
        error = "Could not parse the docker compose project list",
        code = 0,
        reason = "invalid",
      }, list())
    end)

    it("treats output that cannot be parsed as invalid", function()
      stub({ code = 0, stdout = "not json" })

      local result = list()

      assert.is_false(result.ok)
      assert.are.equal("invalid", result.reason)
    end)
  end)

  describe("completing the definition of an existing project", function()
    it("runs with -p when a project name is specified", function()
      -- The default project name derived from the directory name and the project name recorded in
      -- the container labels diverge with COMPOSE_PROJECT_NAME or a -p start. Naming the project
      -- explicitly prevents picking the wrong one.
      stub({ code = 0, stdout = '{"name":"shop","services":{"web":{}}}' })

      local captured
      compose.resolve_project("/work/shop", function(result)
        captured = result
      end, { project_name = "shop" })

      assert.are.same({ "docker", "compose", "-p", "shop", "config", "--format", "json" }, runs[1].cmd)
      assert.are.equal("/work/shop", runs[1].opts.cwd)
      assert.are.same({ "web" }, captured.data.service_names)
    end)
  end)

  describe("run", function()
    it("runs a compose subcommand in the working directory", function()
      stub({ code = 0, stdout = "" })

      compose.run({ "up", "-d", "web" }, "/work/shop", function() end)

      assert.are.same({ "docker", "compose", "up", "-d", "web" }, runs[1].cmd)
      assert.are.equal("/work/shop", runs[1].opts.cwd)
    end)

    it("returns docker's stderr as-is when it fails", function()
      stub({ code = 1, stderr = 'service "nope" is not defined' })

      local captured
      compose.run({ "up", "-d", "nope" }, "/work", function(result)
        captured = result
      end)

      assert.is_false(captured.ok)
      assert.are.equal('service "nope" is not defined', captured.error)
    end)
  end)
end)
