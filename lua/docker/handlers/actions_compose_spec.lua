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

describe("compose のサービス操作とプロジェクト操作", function()
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

  describe("サービス単位の操作", function()
    it("upはデタッチでサービスを起動する", function()
      -- BR-023: 起動はデタッチで行う (Neovim をブロックしない)。
      actions.execute("up", ctx(service({ status = "none" })))

      assert.are.same({ "docker", "compose", "-p", "shop", "up", "-d", "web" }, runs[1].cmd)
    end)

    it("upは行のプロジェクトのcomposeファイルがある場所で実行する", function()
      -- up は compose ファイルを読めないと実行できない。
      actions.execute("up", ctx(service({ status = "none" })))

      assert.are.equal("/work/shop", runs[1].opts.cwd)
    end)

    it("composeファイルの場所が分からないサービスは起動しない", function()
      -- working_dir が失われたプロジェクトでは up を発行しても必ず失敗する。
      actions.execute("up", ctx(service({ status = "none", working_dir = "" })))

      assert.are.same({}, runs)
      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
    end)

    it("stopはサービスを停止する", function()
      actions.execute("stop", ctx(service()))

      assert.are.same({ "docker", "compose", "-p", "shop", "stop", "web" }, runs[1].cmd)
    end)

    it("restartはサービスを再起動する", function()
      actions.execute("restart", ctx(service()))

      assert.are.same({ "docker", "compose", "-p", "shop", "restart", "web" }, runs[1].cmd)
    end)

    it("停止と再起動は作業ディレクトリに依存せず実行する", function()
      -- プロジェクト名で名指しすれば compose ファイルの場所は要らない。
      actions.execute("stop", ctx(service({ working_dir = "" })))

      assert.are.same({ "docker", "compose", "-p", "shop", "stop", "web" }, runs[1].cmd)
      assert.is_nil(runs[1].opts.cwd)
    end)

    it("行のプロジェクトを操作の対象にする", function()
      -- 一覧は全プロジェクトを統合して出すので、対象は行ごとに変わる。
      actions.execute("stop", ctx(service({ project = "blog", name = "cms", working_dir = "/work/blog" })))

      assert.are.same({ "docker", "compose", "-p", "blog", "stop", "cms" }, runs[1].cmd)
    end)

    it("logsはサービスのログをターミナルで追う", function()
      -- プロジェクト名で名指しするので、compose ファイルの場所は要らない。
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

      assert.are.same({ "docker", "compose", "-p", "shop", "up", "-d" }, runs[1].cmd)
      assert.are.equal("/work/shop", runs[1].opts.cwd)
    end)

    it("composeファイルの場所が分からないプロジェクトは起動しない", function()
      actions.execute("project_up", ctx(service({ working_dir = "" })))

      assert.are.same({}, runs)
      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
    end)

    it("project_downは確認でyと答えたときだけ破棄する", function()
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        on_confirm("y")
      end

      actions.execute("project_down", ctx(service({ working_dir = "" })))

      -- 破棄は compose ファイルを読めなくても、プロジェクト名の名指しで実行できる。
      assert.are.same({ "docker", "compose", "-p", "shop", "down" }, runs[1].cmd)
      assert.is_nil(runs[1].opts.cwd)
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
