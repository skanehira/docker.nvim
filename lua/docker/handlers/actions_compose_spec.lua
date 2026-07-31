local actions = require("docker.handlers.actions")
local cli = require("docker.adapters.docker.cli")
local operations = require("docker.handlers.operations")
local registry = require("docker.resources.registry")
local terminal = require("docker.handlers.terminal")

---@param overrides table|nil
---@return table
local function service(overrides)
  return vim.tbl_extend("force", {
    project = "shop",
    name = "web",
    container = "shop-web-1",
    container_id = "abc123",
    status = "running",
    working_dir = "/work/shop",
  }, overrides or {})
end

describe("compose service operations and project operations", function()
  local runs, notified, opened
  local original_notify, original_input
  ---@type docker.ResourceDefinition
  local def

  ---@return docker.ActionContext
  local function ctx(item)
    return { def = def, item = item }
  end

  before_each(function()
    runs, notified, opened = {}, {}, {}
    operations._reset()
    def = assert(registry.get("service"))
    cli._set_executor(function(cmd, opts, on_exit)
      table.insert(runs, { cmd = cmd, opts = opts })
      on_exit({ code = 0, stdout = "", stderr = "" })
    end)
    terminal._set_job_starter(function(cmd)
      table.insert(opened, cmd)
      return 100 + #opened
    end)
    original_notify, original_input = vim.notify, vim.ui.input
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.notify = original_notify
    vim.ui.input = original_input
    cli._set_executor(nil)
    terminal._set_job_starter(nil)
    operations._reset()
  end)

  describe("per-service operations", function()
    it("up starts the service detached", function()
      -- BR-023: startup runs detached (it must not block Neovim).
      actions.execute("up", ctx(service({ status = "none" })))

      assert.are.same({ "docker", "compose", "-p", "shop", "up", "-d", "web" }, runs[1].cmd)
    end)

    it("up runs in the location of the compose file of the row's project", function()
      -- up cannot run without reading the compose file.
      actions.execute("up", ctx(service({ status = "none" })))

      assert.are.equal("/work/shop", runs[1].opts.cwd)
    end)

    it("does not start a service whose compose file location is unknown and tells why", function()
      -- For a project whose working_dir has been lost, issuing up would always fail.
      actions.execute("up", ctx(service({ status = "none", working_dir = "" })))

      assert.are.equal(
        "web は compose ファイルの場所が分からないため起動できません",
        notified[#notified].msg
      )
      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
      assert.are.same({}, runs)
    end)

    it("issues stop with -p when stop is pressed on a running service", function()
      actions.execute("stop", ctx(service()))

      assert.are.same({ "docker", "compose", "-p", "shop", "stop", "web" }, runs[1].cmd)
    end)

    it("issues restart with -p when restart is pressed on a running service", function()
      actions.execute("restart", ctx(service()))

      assert.are.same({ "docker", "compose", "-p", "shop", "restart", "web" }, runs[1].cmd)
    end)

    it("stop and restart run without depending on the working directory", function()
      -- Naming the project explicitly removes the need for the compose file location.
      actions.execute("stop", ctx(service({ working_dir = "" })))

      assert.are.same({ "docker", "compose", "-p", "shop", "stop", "web" }, runs[1].cmd)
      assert.is_nil(runs[1].opts.cwd)
    end)

    it("takes the project of the row as the operation target", function()
      -- The list merges all projects, so the target differs from row to row.
      actions.execute("stop", ctx(service({ project = "blog", name = "cms", working_dir = "/work/blog" })))

      assert.are.same({ "docker", "compose", "-p", "blog", "stop", "cms" }, runs[1].cmd)
    end)

    it("logs follows the service logs in a terminal", function()
      -- The project is named explicitly, so the compose file location is not needed.
      local starts = {}
      terminal._set_job_starter(function(cmd, cwd)
        table.insert(opened, cmd)
        table.insert(starts, { cmd = cmd, cwd = cwd })
        return 100 + #opened
      end)

      actions.execute("logs", ctx(service({ working_dir = "" })))

      assert.are.same({
        { cmd = { "docker", "compose", "-p", "shop", "logs", "-f", "web" } },
      }, starts)
    end)

    it("does not open a terminal for the logs of a service without a container and tells why", function()
      actions.execute("logs", ctx(service({ status = "none", container = "", container_id = "" })))

      assert.are.equal("web はコンテナが無いためログを表示できません", notified[#notified].msg)
      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
      assert.are.same({}, opened)
    end)

    it("does not issue the same operation twice for the same service", function()
      cli._set_executor(function(cmd, opts)
        table.insert(runs, { cmd = cmd, opts = opts })
      end)

      actions.execute("stop", ctx(service()))
      actions.execute("stop", ctx(service()))

      assert.are.equal(1, #runs)
    end)

    it("notifies docker's standard error output as-is on failure", function()
      cli._set_executor(function(cmd, opts, on_exit)
        table.insert(runs, { cmd = cmd, opts = opts })
        on_exit({ code = 1, stdout = "", stderr = 'service "web" is not running' })
      end)

      actions.execute("stop", ctx(service()))

      local last = notified[#notified]
      assert.are.equal(vim.log.levels.ERROR, last.level)
      assert.are.equal('service "web" is not running', last.msg)
    end)
  end)

  describe("per-project operations", function()
    it("project_up starts the whole project detached", function()
      actions.execute("project_up", ctx(service()))

      assert.are.same({ "docker", "compose", "-p", "shop", "up", "-d" }, runs[1].cmd)
      assert.are.equal("/work/shop", runs[1].opts.cwd)
    end)

    it("does not start a project whose compose file location is unknown and tells why", function()
      actions.execute("project_up", ctx(service({ working_dir = "" })))

      assert.are.equal(
        "shop は compose ファイルの場所が分からないため起動できません",
        notified[#notified].msg
      )
      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
      assert.are.same({}, runs)
    end)

    it("project_down tears down only when the confirmation is answered with y", function()
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        on_confirm("y")
      end

      actions.execute("project_down", ctx(service({ working_dir = "" })))

      -- Tearing down works by naming the project even when the compose file cannot be read.
      assert.are.same({ "docker", "compose", "-p", "shop", "down" }, runs[1].cmd)
      assert.is_nil(runs[1].opts.cwd)
    end)

    it("does not tear down when the project_down confirmation is answered with n", function()
      local prompts = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(opts, on_confirm)
        table.insert(prompts, opts.prompt)
        on_confirm("n")
      end

      actions.execute("project_down", ctx(service()))

      -- It must reach the confirmation and still not issue the command. That distinguishes this
      -- from an implementation that simply never shows a confirmation.
      assert.are.same({ "shop を破棄しますか? (y/N): " }, prompts)
      assert.are.same({}, runs)
    end)

    it("includes the project name in the project_down confirmation", function()
      local prompts = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(opts, on_confirm)
        table.insert(prompts, opts.prompt)
        on_confirm("n")
      end

      actions.execute("project_down", ctx(service()))

      assert.is_truthy(prompts[1]:find("shop", 1, true), prompts[1])
    end)

    it("rejects a duplicate project operation while one is running", function()
      cli._set_executor(function(cmd, opts)
        table.insert(runs, { cmd = cmd, opts = opts })
      end)

      actions.execute("project_up", ctx(service()))
      actions.execute("project_up", ctx(service()))

      assert.are.equal(1, #runs)
      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
    end)

    it("exclusion of project operations does not mix with service operations", function()
      cli._set_executor(function(cmd, opts)
        table.insert(runs, { cmd = cmd, opts = opts })
      end)

      actions.execute("project_up", ctx(service()))
      actions.execute("stop", ctx(service()))

      assert.are.equal(2, #runs)
    end)
  end)
end)
