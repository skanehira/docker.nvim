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

  --- docker の実行を横取りし、指定の終了状態を返す。
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

  describe("発行する docker 引数", function()
    it("startは対象のIDでdocker startを発行する", function()
      actions.execute("start", { def = def, item = container({ state = "exited" }) })

      assert.are.same({ "docker", "start", "abc123" }, last_run())
    end)

    it("stopは対象のIDでdocker stopを発行する", function()
      actions.execute("stop", { def = def, item = container({ state = "running" }) })

      assert.are.same({ "docker", "stop", "abc123" }, last_run())
    end)

    it("restartは対象のIDでdocker restartを発行する", function()
      actions.execute("restart", { def = def, item = container({ state = "running" }) })

      assert.are.same({ "docker", "restart", "abc123" }, last_run())
    end)

    it("killは対象のIDでdocker killを発行する", function()
      actions.execute("kill", { def = def, item = container({ state = "running" }) })

      assert.are.same({ "docker", "kill", "abc123" }, last_run())
    end)
  end)

  describe("前提を満たさない操作", function()
    it("実行中のコンテナはstartせず警告する", function()
      actions.execute("start", { def = def, item = container({ state = "running" }) })

      assert.are.same({}, runs, "docker を呼ばないこと")
      assert.are.equal(1, #notified)
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
    end)

    it("停止中のコンテナはstopせず警告する", function()
      actions.execute("stop", { def = def, item = container({ state = "exited" }) })

      assert.are.same({}, runs)
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
    end)

    it("停止中のコンテナはkillせず警告する", function()
      -- BR-007: docker を呼ばずに警告する。
      actions.execute("kill", { def = def, item = container({ state = "exited" }) })

      assert.are.same({}, runs)
      assert.is_truthy(notified[1].msg:find("web", 1, true), "対象名を含めること: " .. notified[1].msg)
    end)

    it("前提を満たさないときは実行中の操作として記録しない", function()
      actions.execute("kill", { def = def, item = container({ state = "exited" }) })

      assert.is_false(operations.is_running("abc123", "kill"))
    end)
  end)

  describe("実行中の重複要求", function()
    it("同じ対象の同じ操作を二重に発行しない", function()
      -- BR-009: 2 つ目のプロセスを起動しない。
      cli._set_executor(function(cmd, _, _)
        table.insert(runs, cmd)
        -- 完了通知を返さず実行中のままにする
      end)

      actions.execute("stop", { def = def, item = container({ state = "running" }) })
      actions.execute("stop", { def = def, item = container({ state = "running" }) })

      assert.are.equal(1, #runs)
    end)

    it("重複要求は警告で知らせる", function()
      cli._set_executor(function(cmd, _, _)
        table.insert(runs, cmd)
      end)
      actions.execute("stop", { def = def, item = container({ state = "running" }) })

      actions.execute("stop", { def = def, item = container({ state = "running" }) })

      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
    end)

    it("完了すると同じ操作を再び受け付ける", function()
      actions.execute("stop", { def = def, item = container({ state = "running" }) })

      actions.execute("stop", { def = def, item = container({ state = "running" }) })

      assert.are.equal(2, #runs)
    end)
  end)

  describe("成否の通知", function()
    it("成功すると対象名を含む情報を通知する", function()
      actions.execute("start", { def = def, item = container({ state = "exited" }) })

      local last = notified[#notified]
      assert.are.equal(vim.log.levels.INFO, last.level)
      assert.is_truthy(last.msg:find("web", 1, true), last.msg)
    end)

    it("失敗するとdockerの標準エラー出力をそのまま通知する", function()
      -- BR-016: docker のエラーはそのまま提示する。
      stub_docker({ code = 1, stderr = "Error response from daemon: cannot stop container" })

      actions.execute("stop", { def = def, item = container({ state = "running" }) })

      local last = notified[#notified]
      assert.are.equal(vim.log.levels.ERROR, last.level)
      assert.are.equal("Error response from daemon: cannot stop container", last.msg)
    end)

    it("失敗しても一覧の状態は変えない", function()
      store.replace_all("container", { container({ state = "running" }) })
      stub_docker({ code = 1, stderr = "boom" })

      actions.execute("stop", { def = def, item = container({ state = "running" }) })

      assert.are.equal("running", store.list("container")[1].state)
    end)

    it("失敗しても実行中の操作は解除される", function()
      stub_docker({ code = 1, stderr = "boom" })

      actions.execute("stop", { def = def, item = container({ state = "running" }) })

      assert.is_false(operations.is_running("abc123", "stop"))
    end)
  end)

  describe("未知のアクション", function()
    it("dockerを呼ばずに警告する", function()
      actions.execute("fly_to_the_moon", { def = def, item = container() })

      assert.are.same({}, runs)
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
    end)
  end)

  describe("対象が無いとき", function()
    it("dockerを呼ばずに警告する", function()
      actions.execute("start", { def = def, item = nil })

      assert.are.same({}, runs)
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
    end)
  end)

  describe("ターミナルを開く操作", function()
    local opened

    before_each(function()
      opened = {}
      terminal._set_opener(function(cmd, _)
        table.insert(opened, cmd)
        local bufnr = vim.api.nvim_create_buf(true, true)
        vim.api.nvim_set_current_buf(bufnr)
        return 100 + #opened
      end)
    end)

    after_each(function()
      terminal._set_opener(nil)
    end)

    it("logsは停止中のコンテナでもターミナルを開く", function()
      actions.execute("logs", { def = def, item = container({ state = "exited" }) })

      assert.are.same({ "docker", "logs", "-f", "abc123" }, opened[1])
    end)

    it("shellは実行中のコンテナでターミナルを開く", function()
      actions.execute("shell", { def = def, item = container({ state = "running" }) })

      assert.are.same({ "docker", "exec", "-it", "abc123" }, { unpack(opened[1], 1, 4) })
    end)

    it("停止中のコンテナではシェルを開かず警告する", function()
      actions.execute("shell", { def = def, item = container({ state = "exited" }) })

      assert.are.same({}, opened)
      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
    end)

    it("execは入力したコマンドでターミナルを開く", function()
      local original_input = vim.ui.input
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        on_confirm("ls -la")
      end

      actions.execute("exec", { def = def, item = container({ state = "running" }) })

      vim.ui.input = original_input
      assert.are.same({ "docker", "exec", "-it", "abc123", "ls", "-la" }, opened[1])
    end)

    it("execの入力をキャンセルするとターミナルを開かない", function()
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
end)
