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

describe("delete action", function()
  local runs, notified, prompts
  local original_notify, original_input
  ---@type docker.ResourceDefinition
  local def

  --- Sets up the answer to be given to the confirmation prompt.
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

  it("issues the delete command when the confirmation is answered with y", function()
    answer_with("y")

    actions.execute("delete", { def = def, item = container() })

    assert.are.same({ "docker", "rm", "abc123" }, runs[1])
  end)

  it("deletes when the confirmation is answered with an uppercase Y", function()
    answer_with("Y")

    actions.execute("delete", { def = def, item = container() })

    assert.are.same({ "docker", "rm", "abc123" }, runs[1])
  end)

  it("does not issue the delete command when the confirmation is answered with n", function()
    answer_with("n")

    actions.execute("delete", { def = def, item = container() })

    assert.are.same({}, runs)
  end)

  it("does not delete when the confirmation is an empty string", function()
    answer_with("")

    actions.execute("delete", { def = def, item = container() })

    assert.are.same({}, runs)
  end)

  it("does not delete when the confirmation is cancelled", function()
    -- Leaving with Esc returns nil.
    answer_with(nil)

    actions.execute("delete", { def = def, item = container() })

    assert.are.same({}, runs)
  end)

  it("does not delete for an answer other than y such as yes", function()
    answer_with("yes")

    actions.execute("delete", { def = def, item = container() })

    assert.are.same({}, runs)
  end)

  it("includes the target name in the confirmation prompt", function()
    answer_with("n")

    actions.execute("delete", { def = def, item = container({ name = "my-container" }) })

    assert.are.equal(1, #prompts)
    assert.is_truthy(prompts[1].prompt:find("my-container", 1, true), prompts[1].prompt)
  end)

  it("does not add a force delete option", function()
    -- BR-002: deleting a running container is left for docker to refuse; it is never forced with -f.
    answer_with("y")

    actions.execute("delete", { def = def, item = container() })

    for _, arg in ipairs(runs[1]) do
      assert.is_true(arg ~= "-f" and arg ~= "--force", "must not include a force delete option")
    end
  end)

  it("notifies docker's standard error output as-is when the delete fails", function()
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

  it("leaves no running operation when the delete is declined", function()
    answer_with("n")

    actions.execute("delete", { def = def, item = container() })

    assert.is_false(operations.is_running("abc123", "delete"))
  end)

  it("clears the running operation once the delete completes", function()
    answer_with("y")

    actions.execute("delete", { def = def, item = container() })

    assert.is_false(operations.is_running("abc123", "delete"))
  end)

  describe("delete across all resource kinds", function()
    it("issues the correct delete command for each kind", function()
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

    it("goes through the confirmation prompt for every kind", function()
      -- G6: deletion interposes a confirmation regardless of the kind.
      answer_with("n")

      for _, kind in ipairs({ "container", "image", "volume", "network" }) do
        runs, prompts = {}, {}
        actions.execute("delete", {
          def = assert(registry.get(kind)),
          item = { id = "x", name = "x" },
        })
        assert.are.equal(1, #prompts, kind .. " must show a confirmation")
        assert.are.same({}, runs, kind .. " must not issue the delete command")
      end
    end)

    it("does not add a force delete option for any kind", function()
      answer_with("y")

      for _, kind in ipairs({ "container", "image", "volume", "network" }) do
        runs = {}
        actions.execute("delete", { def = assert(registry.get(kind)), item = { id = "x", name = "x" } })
        for _, arg in ipairs(runs[1]) do
          assert.is_true(arg ~= "-f" and arg ~= "--force", kind .. " must not include a force delete")
        end
      end
    end)
  end)
end)
