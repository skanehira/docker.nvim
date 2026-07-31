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
    notify.info("nginx を起動しました")

    assert.are.same({
      { msg = "nginx を起動しました", level = vim.log.levels.INFO, opts = { title = "docker.nvim" } },
    }, calls)
  end)

  it("attaches the WARN level and the plugin name as the title when notifying via warn", function()
    notify.warn("実行中ではないため kill できません")

    assert.are.same({
      {
        msg = "実行中ではないため kill できません",
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
    notify.info("1 件目")
    notify.error("2 件目")

    assert.are.same({
      { msg = "1 件目", level = vim.log.levels.INFO, opts = { title = "docker.nvim" } },
      { msg = "2 件目", level = vim.log.levels.ERROR, opts = { title = "docker.nvim" } },
    }, calls)
  end)
end)
