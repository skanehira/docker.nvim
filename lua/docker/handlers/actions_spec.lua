local actions = require("docker.handlers.actions")
local cli = require("docker.adapters.docker.cli")
local operations = require("docker.handlers.operations")
local registry = require("docker.resources.registry")
local store = require("docker.state.store")
local terminal = require("docker.handlers.terminal")

---@param overrides table|nil
---@return table
local function container(overrides)
  return vim.tbl_extend("force", {
    id = "abc123",
    name = "web",
    image = "alpine:3.20",
    state = "running",
    status = "Up 5 days",
    ports = "",
    command = '"sleep 600"',
    created_at = "2026-07-29 10:00:00 +0900 JST",
    compose_project = "",
    compose_service = "",
    compose_oneoff = "",
  }, overrides or {})
end

describe("docker.handlers.actions", function()
  local runs
  local notified
  local original_notify
  ---@type docker.ResourceDefinition
  local def

  --- Intercepts the docker execution and returns the given exit status.
  local function stub_docker(out)
    cli._set_executor(function(cmd, _, on_exit)
      table.insert(runs, cmd)
      on_exit({ code = out.code, stdout = out.stdout or "", stderr = out.stderr or "" })
    end)
  end

  before_each(function()
    runs, notified = {}, {}
    store._reset()
    operations._reset()
    def = assert(registry.get("container"))
    stub_docker({ code = 0 })
    original_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.notify = original_notify
    cli._set_executor(nil)
    store._reset()
    operations._reset()
  end)

  ---@return string[]|nil
  local function last_run()
    return runs[#runs]
  end

  describe("docker arguments issued", function()
    it("start issues docker start with the target ID", function()
      actions.execute("start", { def = def, item = container({ state = "exited" }) })

      assert.are.same({ "docker", "start", "abc123" }, last_run())
    end)

    it("stop issues docker stop with the target ID", function()
      actions.execute("stop", { def = def, item = container({ state = "running" }) })

      assert.are.same({ "docker", "stop", "abc123" }, last_run())
    end)

    it("restart issues docker restart with the target ID", function()
      actions.execute("restart", { def = def, item = container({ state = "running" }) })

      assert.are.same({ "docker", "restart", "abc123" }, last_run())
    end)

    it("kill issues docker kill with the target ID", function()
      actions.execute("kill", { def = def, item = container({ state = "running" }) })

      assert.are.same({ "docker", "kill", "abc123" }, last_run())
    end)
  end)

  describe("operations that do not satisfy their precondition", function()
    it("warns instead of starting a running container", function()
      actions.execute("start", { def = def, item = container({ state = "running" }) })

      assert.are.same({}, runs, "must not invoke docker")
      assert.are.equal(1, #notified)
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
    end)

    it("warns instead of stopping a stopped container", function()
      actions.execute("stop", { def = def, item = container({ state = "exited" }) })

      assert.are.same({}, runs)
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
    end)

    it("warns instead of killing a stopped container", function()
      -- BR-007: warn without invoking docker.
      actions.execute("kill", { def = def, item = container({ state = "exited" }) })

      assert.are.same({}, runs)
      assert.is_truthy(notified[1].msg:find("web", 1, true), "must include the target name: " .. notified[1].msg)
    end)

    it("does not record a running operation when the precondition is not satisfied", function()
      actions.execute("kill", { def = def, item = container({ state = "exited" }) })

      assert.is_false(operations.is_running("abc123", "kill"))
    end)
  end)

  describe("duplicate requests while an operation is running", function()
    it("does not issue the same operation twice for the same target", function()
      -- BR-009: do not start a second process.
      cli._set_executor(function(cmd, _, _)
        table.insert(runs, cmd)
        -- Leave it running by never delivering a completion notification
      end)

      actions.execute("stop", { def = def, item = container({ state = "running" }) })
      actions.execute("stop", { def = def, item = container({ state = "running" }) })

      assert.are.equal(1, #runs)
    end)

    it("reports a duplicate request with a warning", function()
      cli._set_executor(function(cmd, _, _)
        table.insert(runs, cmd)
      end)
      actions.execute("stop", { def = def, item = container({ state = "running" }) })

      actions.execute("stop", { def = def, item = container({ state = "running" }) })

      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
    end)

    it("accepts the same operation again once it has completed", function()
      actions.execute("stop", { def = def, item = container({ state = "running" }) })

      actions.execute("stop", { def = def, item = container({ state = "running" }) })

      assert.are.equal(2, #runs)
    end)
  end)

  describe("notification of success and failure", function()
    it("notifies info including the target name on success", function()
      actions.execute("start", { def = def, item = container({ state = "exited" }) })

      local last = notified[#notified]
      assert.are.equal(vim.log.levels.INFO, last.level)
      assert.is_truthy(last.msg:find("web", 1, true), last.msg)
    end)

    it("notifies docker's standard error output as-is on failure", function()
      -- BR-016: docker's error is presented as-is.
      stub_docker({ code = 1, stderr = "Error response from daemon: cannot stop container" })

      actions.execute("stop", { def = def, item = container({ state = "running" }) })

      local last = notified[#notified]
      assert.are.equal(vim.log.levels.ERROR, last.level)
      assert.are.equal("Error response from daemon: cannot stop container", last.msg)
    end)

    it("does not change the state in the list on failure", function()
      store.replace_all("container", { container({ state = "running" }) })
      stub_docker({ code = 1, stderr = "boom" })

      actions.execute("stop", { def = def, item = container({ state = "running" }) })

      assert.are.equal("running", store.list("container")[1].state)
    end)

    it("clears the running operation even on failure", function()
      stub_docker({ code = 1, stderr = "boom" })

      actions.execute("stop", { def = def, item = container({ state = "running" }) })

      assert.is_false(operations.is_running("abc123", "stop"))
    end)
  end)

  describe("unknown action", function()
    it("warns without invoking docker", function()
      actions.execute("fly_to_the_moon", { def = def, item = container() })

      assert.are.same({}, runs)
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
    end)
  end)

  describe("when there is no target", function()
    it("warns without invoking docker", function()
      actions.execute("start", { def = def, item = nil })

      assert.are.same({}, runs)
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
    end)
  end)

  describe("operations that open a terminal", function()
    local opened

    before_each(function()
      opened = {}
      terminal._set_job_starter(function(cmd)
        table.insert(opened, cmd)
        return 100 + #opened
      end)
    end)

    after_each(function()
      terminal._set_job_starter(nil)
    end)

    it("logs opens a terminal even for a stopped container", function()
      actions.execute("logs", { def = def, item = container({ state = "exited" }) })

      assert.are.same({ "docker", "logs", "-f", "abc123" }, opened[1])
    end)

    it("shell opens a terminal for a running container", function()
      actions.execute("shell", { def = def, item = container({ state = "running" }) })

      assert.are.same({ "docker", "exec", "-it", "abc123" }, { unpack(opened[1], 1, 4) })
    end)

    it("warns instead of opening a shell for a stopped container", function()
      actions.execute("shell", { def = def, item = container({ state = "exited" }) })

      assert.are.same({}, opened)
      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
    end)

    it("exec opens a terminal with the entered command", function()
      local original_input = vim.ui.input
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        on_confirm("ls -la")
      end

      actions.execute("exec", { def = def, item = container({ state = "running" }) })

      vim.ui.input = original_input
      assert.are.same({ "docker", "exec", "-it", "abc123", "ls", "-la" }, opened[1])
    end)

    it("does not open a terminal when the exec input is cancelled", function()
      local original_input = vim.ui.input
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        on_confirm(nil)
      end

      actions.execute("exec", { def = def, item = container({ state = "running" }) })

      vim.ui.input = original_input
      assert.are.same({}, opened)
    end)
  end)

  describe("notification wording", function()
    it("notifies with wording that tells what happened for each operation", function()
      local messages = {}
      for _, case in ipairs({
        { action = "start", state = "exited" },
        { action = "stop", state = "running" },
        { action = "restart", state = "running" },
        { action = "kill", state = "running" },
      }) do
        notified = {}
        actions.execute(case.action, { def = def, item = container({ state = case.state }) })
        table.insert(messages, notified[#notified].msg)
      end

      assert.are.same({
        "Started web",
        "Stopped web",
        "Restarted web",
        "Killed web",
      }, messages)
    end)

    it("refuses an operation whose precondition is unmet with wording that tells why", function()
      local messages = {}
      for _, case in ipairs({
        { action = "start", state = "running" },
        { action = "stop", state = "exited" },
        { action = "kill", state = "exited" },
      }) do
        notified = {}
        actions.execute(case.action, { def = def, item = container({ state = case.state }) })
        table.insert(messages, notified[#notified].msg)
      end

      assert.are.same({
        "web is already running",
        "web is not running, so it cannot be stopped",
        "web is not running, so it cannot be killed",
      }, messages)
    end)
  end)

  describe("precondition of restart", function()
    it("restarts even a stopped container", function()
      -- docker restart starts a stopped container. It must not be rejected by a precondition.
      actions.execute("restart", { def = def, item = container({ state = "exited" }) })

      assert.are.same({ "docker", "restart", "abc123" }, last_run())
    end)
  end)

  describe("pause and unpause", function()
    it("pauses a running container", function()
      actions.execute("pause", { def = def, item = container({ state = "running" }) })

      assert.are.same({ "docker", "pause", "abc123" }, last_run())
    end)

    it("unpauses a paused container", function()
      actions.execute("unpause", { def = def, item = container({ state = "paused" }) })

      assert.are.same({ "docker", "unpause", "abc123" }, last_run())
    end)

    it("warns instead of pausing a stopped container", function()
      actions.execute("pause", { def = def, item = container({ state = "exited" }) })

      assert.are.same({}, runs)
      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
    end)

    it("warns instead of unpausing a container that is not paused", function()
      actions.execute("unpause", { def = def, item = container({ state = "running" }) })

      assert.are.same({}, runs)
      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
    end)
  end)
end)
