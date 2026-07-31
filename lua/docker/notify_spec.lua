local notify = require("docker.notify")

describe("docker.notify", function()
  local original_notify
  local calls

  before_each(function()
    calls = {}
    original_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level, opts)
      table.insert(calls, { msg = msg, level = level, opts = opts })
    end
  end)

  after_each(function()
    vim.notify = original_notify
    -- The debug flag stays in the module, so it must not leak between tests.
    notify.set_debug(false)
  end)

  it("attaches the INFO level and the plugin name as the title when notifying via info", function()
    notify.info("Started nginx")

    assert.are.same({
      { msg = "Started nginx", level = vim.log.levels.INFO, opts = { title = "docker.nvim" } },
    }, calls)
  end)

  it("attaches the WARN level and the plugin name as the title when notifying via warn", function()
    notify.warn("nginx is not running, so it cannot be killed")

    assert.are.same({
      {
        msg = "nginx is not running, so it cannot be killed",
        level = vim.log.levels.WARN,
        opts = { title = "docker.nvim" },
      },
    }, calls)
  end)

  it("attaches the ERROR level and the plugin name as the title when notifying via error", function()
    notify.error("Error response from daemon: conflict")

    assert.are.same({
      {
        msg = "Error response from daemon: conflict",
        level = vim.log.levels.ERROR,
        opts = { title = "docker.nvim" },
      },
    }, calls)
  end)

  it("emits no debug output by default", function()
    notify.debug("docker ps -a (exit 0)")

    assert.are.same({}, calls)
  end)

  it("emits at the DEBUG level once debug output is enabled", function()
    notify.set_debug(true)

    notify.debug("docker ps -a (exit 0)")

    assert.are.same({
      { msg = "docker ps -a (exit 0)", level = vim.log.levels.DEBUG, opts = { title = "docker.nvim" } },
    }, calls)
  end)

  it("stops emitting once debug output is disabled again", function()
    notify.set_debug(true)
    notify.set_debug(false)

    notify.debug("docker ps -a (exit 0)")

    assert.are.same({}, calls)
  end)

  it("emits every notification in call order when notifying several times", function()
    notify.info("first")
    notify.error("second")

    assert.are.same({
      { msg = "first", level = vim.log.levels.INFO, opts = { title = "docker.nvim" } },
      { msg = "second", level = vim.log.levels.ERROR, opts = { title = "docker.nvim" } },
    }, calls)
  end)
end)
