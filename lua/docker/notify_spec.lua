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
    -- デバッグ状態はモジュールに残るため、テスト間に漏らさない。
    notify.set_debug(false)
  end)

  it("info_で通知するとINFOレベルとプラグイン名のタイトルが付く", function()
    notify.info("nginx を起動しました")

    assert.are.same({
      { msg = "nginx を起動しました", level = vim.log.levels.INFO, opts = { title = "docker.nvim" } },
    }, calls)
  end)

  it("warn_で通知するとWARNレベルとプラグイン名のタイトルが付く", function()
    notify.warn("実行中ではないため kill できません")

    assert.are.same({
      {
        msg = "実行中ではないため kill できません",
        level = vim.log.levels.WARN,
        opts = { title = "docker.nvim" },
      },
    }, calls)
  end)

  it("error_で通知するとERRORレベルとプラグイン名のタイトルが付く", function()
    notify.error("Error response from daemon: conflict")

    assert.are.same({
      {
        msg = "Error response from daemon: conflict",
        level = vim.log.levels.ERROR,
        opts = { title = "docker.nvim" },
      },
    }, calls)
  end)

  it("デバッグ出力は既定では発行されない", function()
    notify.debug("docker ps -a (exit 0)")

    assert.are.same({}, calls)
  end)

  it("デバッグを有効にするとDEBUGレベルで発行される", function()
    notify.set_debug(true)

    notify.debug("docker ps -a (exit 0)")

    assert.are.same({
      { msg = "docker ps -a (exit 0)", level = vim.log.levels.DEBUG, opts = { title = "docker.nvim" } },
    }, calls)
  end)

  it("デバッグを再び無効にすると発行されなくなる", function()
    notify.set_debug(true)
    notify.set_debug(false)

    notify.debug("docker ps -a (exit 0)")

    assert.are.same({}, calls)
  end)

  it("複数回通知すると呼び出した順にすべて発行される", function()
    notify.info("1 件目")
    notify.error("2 件目")

    assert.are.same({
      { msg = "1 件目", level = vim.log.levels.INFO, opts = { title = "docker.nvim" } },
      { msg = "2 件目", level = vim.log.levels.ERROR, opts = { title = "docker.nvim" } },
    }, calls)
  end)
end)
