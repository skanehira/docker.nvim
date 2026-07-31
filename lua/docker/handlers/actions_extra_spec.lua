local actions = require("docker.handlers.actions")
local cli = require("docker.adapters.docker.cli")
local operations = require("docker.handlers.operations")
local registry = require("docker.resources.registry")
local terminal = require("docker.handlers.terminal")

---@param overrides table|nil
---@return table
local function container(overrides)
  return vim.tbl_extend("force", {
    id = "abc123",
    name = "web",
    image = "alpine",
    state = "running",
    status = "Up",
    ports = "0.0.0.0:8080->80/tcp",
    command = "x",
    created_at = "now",
    compose_project = "",
    compose_service = "",
    compose_oneoff = "",
  }, overrides or {})
end

describe("extra actions", function()
  local runs, notified, opened, inputs, selects, urls
  local original_notify, original_input, original_select, original_ui_open

  before_each(function()
    runs, notified, opened, inputs, selects, urls = {}, {}, {}, {}, {}, {}
    operations._reset()
    cli._set_executor(function(cmd, _, on_exit)
      table.insert(runs, cmd)
      on_exit({ code = 0, stdout = "", stderr = "" })
    end)
    terminal._set_job_starter(function(cmd)
      table.insert(opened, cmd)
      return 100 + #opened
    end)
    original_notify, original_input = vim.notify, vim.ui.input
    original_select, original_ui_open = vim.ui.select, vim.ui.open
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.open = function(url)
      table.insert(urls, url)
      return { wait = function() end }
    end
  end)

  after_each(function()
    vim.notify, vim.ui.input = original_notify, original_input
    vim.ui.select, vim.ui.open = original_select, original_ui_open
    cli._set_executor(nil)
    terminal._set_job_starter(nil)
    operations._reset()
  end)

  ---@param answer string|nil
  local function answer_with(answer)
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.input = function(opts, on_confirm)
      table.insert(inputs, opts)
      on_confirm(answer)
    end
  end

  ---@param index integer|nil position of the candidate to choose (nil cancels the selection)
  local function select_index(index)
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, opts, on_choice)
      table.insert(selects, { items = items, opts = opts })
      if index then
        on_choice(items[index], index)
      else
        on_choice(nil, nil)
      end
    end
  end

  describe("quickrun (image)", function()
    ---@return docker.ActionContext
    local function ctx(item)
      return { def = assert(registry.get("image")), item = item }
    end

    it("opens a shell in a throwaway container", function()
      actions.execute("quickrun", ctx({ id = "img1", repository = "alpine", tag = "3.20" }))

      assert.are.same({ "docker", "run", "--rm", "-it", "--entrypoint", "sh", "alpine:3.20" }, opened[1])
    end)

    it("starts an image that has no tag by its ID", function()
      actions.execute("quickrun", ctx({ id = "img1", repository = "<none>", tag = "<none>" }))

      assert.are.same({ "docker", "run", "--rm", "-it", "--entrypoint", "sh", "img1" }, opened[1])
    end)
  end)

  describe("open_browser", function()
    ---@return docker.ActionContext
    local function ctx(item)
      return { def = assert(registry.get("container")), item = item }
    end

    it("opens that URL when there is a single published port", function()
      actions.execute("open_browser", ctx(container()))

      assert.are.same({ "http://localhost:8080" }, urls)
    end)

    it("asks for a choice when there are several published ports", function()
      select_index(2)

      actions.execute("open_browser", ctx(container({ ports = "0.0.0.0:8080->80/tcp, 0.0.0.0:9090->90/tcp" })))

      assert.are.same({ "http://localhost:8080", "http://localhost:9090" }, selects[1].items)
      assert.are.same({ "http://localhost:9090" }, urls)
    end)

    it("opens nothing when the selection is cancelled", function()
      select_index(nil)

      actions.execute("open_browser", ctx(container({ ports = "0.0.0.0:8080->80/tcp, 0.0.0.0:9090->90/tcp" })))

      assert.are.same({}, urls)
    end)

    it("opens nothing and tells the user when there is no published port", function()
      actions.execute("open_browser", ctx(container({ ports = "" })))

      assert.are.same({}, urls)
      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
    end)
  end)

  describe("file copy", function()
    ---@return docker.ActionContext
    local function ctx()
      return { def = assert(registry.get("container")), item = container() }
    end

    it("copy_to copies from the host into the container", function()
      local answers = { "/host/file.txt", "/app/file.txt" }
      local turn = 0
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(opts, on_confirm)
        turn = turn + 1
        table.insert(inputs, opts)
        on_confirm(answers[turn])
      end

      actions.execute("copy_to", ctx())

      assert.are.same({ "docker", "cp", "/host/file.txt", "abc123:/app/file.txt" }, runs[1])
    end)

    it("copy_from copies from the container onto the host", function()
      local answers = { "/app/file.txt", "/host/file.txt" }
      local turn = 0
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(opts, on_confirm)
        turn = turn + 1
        table.insert(inputs, opts)
        on_confirm(answers[turn])
      end

      actions.execute("copy_from", ctx())

      assert.are.same({ "docker", "cp", "abc123:/app/file.txt", "/host/file.txt" }, runs[1])
    end)

    it("does not copy when the input is cancelled", function()
      answer_with(nil)

      actions.execute("copy_to", ctx())

      assert.are.same({}, runs)
    end)

    it("does not copy when the second input is cancelled either", function()
      local turn = 0
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(opts, on_confirm)
        turn = turn + 1
        table.insert(inputs, opts)
        on_confirm(turn == 1 and "/host/file.txt" or nil)
      end

      actions.execute("copy_to", ctx())

      assert.are.same({}, runs)
    end)

    it("notifies docker's standard error output as-is on failure", function()
      local turn = 0
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        turn = turn + 1
        on_confirm(turn == 1 and "/host/x" or "/app/x")
      end
      cli._set_executor(function(cmd, _, on_exit)
        table.insert(runs, cmd)
        on_exit({ code = 1, stdout = "", stderr = "no such file or directory" })
      end)

      actions.execute("copy_to", ctx())

      local last = notified[#notified]
      assert.are.equal(vim.log.levels.ERROR, last.level)
      assert.are.equal("no such file or directory", last.msg)
    end)
  end)
end)
