local actions = require("docker.handlers.actions")
local cli = require("docker.adapters.docker.cli")
local operations = require("docker.handlers.operations")
local registry = require("docker.resources.registry")

---@param overrides table|nil
---@return table
local function container(overrides)
  return vim.tbl_extend("force", {
    id = "abc123",
    name = "web",
    image = "alpine:3.20",
    state = "exited",
    status = "Exited (0) 1 minute ago",
    ports = "",
    command = '"sleep 600"',
    created_at = "2026-07-29 10:00:00 +0900 JST",
    compose_project = "",
    compose_service = "",
    compose_oneoff = "",
  }, overrides or {})
end

describe("削除アクション", function()
  local runs, notified, prompts
  local original_notify, original_input
  ---@type docker.ResourceDefinition
  local def

  --- 確認プロンプトへ与える応答を仕込む。
  ---@param answer string|nil
  local function answer_with(answer)
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.input = function(opts, on_confirm)
      table.insert(prompts, opts)
      on_confirm(answer)
    end
  end

  before_each(function()
    runs, notified, prompts = {}, {}, {}
    operations._reset()
    def = assert(registry.get("container"))
    cli._set_executor(function(cmd, _, on_exit)
      table.insert(runs, cmd)
      on_exit({ code = 0, stdout = "", stderr = "" })
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
    operations._reset()
  end)

  it("確認でyと答えると削除コマンドを発行する", function()
    answer_with("y")

    actions.execute("delete", { def = def, item = container() })

    assert.are.same({ "docker", "rm", "abc123" }, runs[1])
  end)

  it("確認で大文字のYと答えても削除する", function()
    answer_with("Y")

    actions.execute("delete", { def = def, item = container() })

    assert.are.same({ "docker", "rm", "abc123" }, runs[1])
  end)

  it("確認でnと答えると削除コマンドを発行しない", function()
    answer_with("n")

    actions.execute("delete", { def = def, item = container() })

    assert.are.same({}, runs)
  end)

  it("確認で空文字のときは削除しない", function()
    answer_with("")

    actions.execute("delete", { def = def, item = container() })

    assert.are.same({}, runs)
  end)

  it("確認をキャンセルすると削除しない", function()
    -- Esc で抜けると nil が返る。
    answer_with(nil)

    actions.execute("delete", { def = def, item = container() })

    assert.are.same({}, runs)
  end)

  it("yes のような y 以外の応答では削除しない", function()
    answer_with("yes")

    actions.execute("delete", { def = def, item = container() })

    assert.are.same({}, runs)
  end)

  it("確認プロンプトに対象名を含める", function()
    answer_with("n")

    actions.execute("delete", { def = def, item = container({ name = "my-container" }) })

    assert.are.equal(1, #prompts)
    assert.is_truthy(prompts[1].prompt:find("my-container", 1, true), prompts[1].prompt)
  end)

  it("強制削除のオプションを付けない", function()
    -- BR-002: 実行中コンテナの削除は docker に拒否させ、-f では消さない。
    answer_with("y")

    actions.execute("delete", { def = def, item = container() })

    for _, arg in ipairs(runs[1]) do
      assert.is_true(arg ~= "-f" and arg ~= "--force", "強制削除のオプションを含めないこと")
    end
  end)

  it("削除に失敗するとdockerの標準エラー出力をそのまま通知する", function()
    answer_with("y")
    cli._set_executor(function(cmd, _, on_exit)
      table.insert(runs, cmd)
      on_exit({ code = 1, stdout = "", stderr = "Error response from daemon: container is running" })
    end)

    actions.execute("delete", { def = def, item = container({ state = "running" }) })

    local last = notified[#notified]
    assert.are.equal(vim.log.levels.ERROR, last.level)
    assert.are.equal("Error response from daemon: container is running", last.msg)
  end)

  it("削除を断ったときは実行中の操作として残らない", function()
    answer_with("n")

    actions.execute("delete", { def = def, item = container() })

    assert.is_false(operations.is_running("abc123", "delete"))
  end)

  it("削除が完了すると実行中の操作が解除される", function()
    answer_with("y")

    actions.execute("delete", { def = def, item = container() })

    assert.is_false(operations.is_running("abc123", "delete"))
  end)

  describe("全リソース種別の削除", function()
    it("種別ごとに正しい削除コマンドを発行する", function()
      answer_with("y")
      local cases = {
        { kind = "container", item = container(), expected = { "docker", "rm", "abc123" } },
        { kind = "image", item = { id = "img1", repository = "alpine" }, expected = { "docker", "rmi", "img1" } },
        { kind = "volume", item = { name = "vol1" }, expected = { "docker", "volume", "rm", "vol1" } },
        { kind = "network", item = { id = "net1", name = "mynet" }, expected = { "docker", "network", "rm", "net1" } },
      }

      local actual = {}
      for _, case in ipairs(cases) do
        runs = {}
        actions.execute("delete", { def = assert(registry.get(case.kind)), item = case.item })
        table.insert(actual, runs[1])
      end

      assert.are.same({ cases[1].expected, cases[2].expected, cases[3].expected, cases[4].expected }, actual)
    end)

    it("どの種別でも確認プロンプトを経る", function()
      -- G6: 削除は種別に依らず確認を挟む。
      answer_with("n")

      for _, kind in ipairs({ "container", "image", "volume", "network" }) do
        runs, prompts = {}, {}
        actions.execute("delete", {
          def = assert(registry.get(kind)),
          item = { id = "x", name = "x" },
        })
        assert.are.equal(1, #prompts, kind .. " で確認が出ること")
        assert.are.same({}, runs, kind .. " で削除コマンドを発行しないこと")
      end
    end)

    it("どの種別でも強制削除のオプションを付けない", function()
      answer_with("y")

      for _, kind in ipairs({ "container", "image", "volume", "network" }) do
        runs = {}
        actions.execute("delete", { def = assert(registry.get(kind)), item = { id = "x", name = "x" } })
        for _, arg in ipairs(runs[1]) do
          assert.is_true(arg ~= "-f" and arg ~= "--force", kind .. " に強制削除を含めないこと")
        end
      end
    end)
  end)
end)
