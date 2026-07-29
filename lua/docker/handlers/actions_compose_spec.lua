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
  }, overrides or {})
end

describe("compose のサービス操作とプロジェクト操作", function()
  local runs, notified, opened
  local original_notify, original_input
  ---@type docker.ResourceDefinition
  local def

  ---@return docker.ActionContext
  local function ctx(item)
    return { def = def, item = item, cwd = "/work/shop", project = { name = "shop", working_dir = "/work/shop" } }
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

  describe("サービス単位の操作", function()
    it("upはデタッチでサービスを起動する", function()
      -- BR-023: 起動はデタッチで行う (Neovim をブロックしない)。
      actions.execute("up", ctx(service({ status = "none" })))

      assert.are.same({ "docker", "compose", "up", "-d", "web" }, runs[1].cmd)
    end)

    it("stopはサービスを停止する", function()
      actions.execute("stop", ctx(service()))

      assert.are.same({ "docker", "compose", "stop", "web" }, runs[1].cmd)
    end)

    it("restartはサービスを再起動する", function()
      actions.execute("restart", ctx(service()))

      assert.are.same({ "docker", "compose", "restart", "web" }, runs[1].cmd)
    end)

    it("ビューを開いた時点の作業ディレクトリで実行する", function()
      -- BR-003: compose の対象は開いた時点の cwd で解決したプロジェクト。
      actions.execute("stop", ctx(service()))

      assert.are.equal("/work/shop", runs[1].opts.cwd)
    end)

    it("logsはサービスのログをターミナルで追う", function()
      actions.execute("logs", ctx(service()))

      assert.are.same({ "docker", "compose", "logs", "-f", "web" }, opened[1])
    end)

    it("logsもプロジェクトの作業ディレクトリで実行する", function()
      -- cwd を渡さないと、別のディレクトリの compose プロジェクトのログを見てしまう。
      local cwds = {}
      terminal._set_job_starter(function(cmd, cwd)
        table.insert(opened, cmd)
        table.insert(cwds, cwd)
        return 100 + #opened
      end)

      actions.execute("logs", ctx(service()))

      assert.are.same({ "/work/shop" }, cwds)
    end)

    it("コンテナが無いサービスのログではターミナルを開かない", function()
      actions.execute("logs", ctx(service({ status = "none", container = "", container_id = "" })))

      assert.are.same({}, opened)
      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
    end)

    it("同じサービスへの同じ操作を二重に発行しない", function()
      cli._set_executor(function(cmd, opts)
        table.insert(runs, { cmd = cmd, opts = opts })
      end)

      actions.execute("stop", ctx(service()))
      actions.execute("stop", ctx(service()))

      assert.are.equal(1, #runs)
    end)

    it("失敗するとdockerの標準エラー出力をそのまま通知する", function()
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

  describe("プロジェクト単位の操作", function()
    it("project_upはプロジェクト全体をデタッチで起動する", function()
      actions.execute("project_up", ctx(service()))

      assert.are.same({ "docker", "compose", "up", "-d" }, runs[1].cmd)
    end)

    it("project_downは確認でyと答えたときだけ破棄する", function()
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        on_confirm("y")
      end

      actions.execute("project_down", ctx(service()))

      assert.are.same({ "docker", "compose", "down" }, runs[1].cmd)
    end)

    it("project_downの確認でnと答えると破棄しない", function()
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        on_confirm("n")
      end

      actions.execute("project_down", ctx(service()))

      assert.are.same({}, runs)
    end)

    it("project_downの確認にプロジェクト名を含める", function()
      local prompts = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(opts, on_confirm)
        table.insert(prompts, opts.prompt)
        on_confirm("n")
      end

      actions.execute("project_down", ctx(service()))

      assert.is_truthy(prompts[1]:find("shop", 1, true), prompts[1])
    end)

    it("プロジェクト操作も実行中は重複を拒否する", function()
      cli._set_executor(function(cmd, opts)
        table.insert(runs, { cmd = cmd, opts = opts })
      end)

      actions.execute("project_up", ctx(service()))
      actions.execute("project_up", ctx(service()))

      assert.are.equal(1, #runs)
      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
    end)

    it("プロジェクト操作の排他はサービス操作と混ざらない", function()
      cli._set_executor(function(cmd, opts)
        table.insert(runs, { cmd = cmd, opts = opts })
      end)

      actions.execute("project_up", ctx(service()))
      actions.execute("stop", ctx(service()))

      assert.are.equal(2, #runs)
    end)
  end)
end)
