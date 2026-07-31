local highlight = require("docker.ui.highlight")
local operations = require("docker.handlers.operations")
local list = require("docker.views.list")
local registry = require("docker.resources.registry")
local store = require("docker.state.store")
local window = require("docker.ui.window")

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

describe("state display of the list view", function()
  ---@type docker.ResourceDefinition
  local def
  local handle

  before_each(function()
    store._reset()
    operations._reset()
    def = assert(registry.get("container"))
    handle = window.open({ title = "Containers" })
  end)

  after_each(function()
    if handle then
      window.close(handle)
      handle = nil
    end
  end)

  ---@return table[]
  local function marks()
    return vim.api.nvim_buf_get_extmarks(handle.bufnr, highlight.namespace(), 0, -1, { details = true })
  end

  ---@param lnum integer 1-based
  ---@return string
  local function status_text_at(lnum)
    local got = marks()[lnum]
    local line = vim.api.nvim_buf_get_lines(handle.bufnr, got[2], got[2] + 1, false)[1]
    return line:sub(got[3] + 1, got[4].end_col)
  end

  it("changes the text of the STATUS column when the state in the store changes", function()
    store.replace_all("container", { container({ state = "running", status = "Up 5 days" }) })
    list.render(handle, def, store.list("container"))
    assert.are.equal("Up 5 days", status_text_at(1))

    store.upsert("container", container({ state = "exited", status = "Exited (0) 1 minute ago" }))
    list.render(handle, def, store.list("container"))

    assert.are.equal("Exited (0) 1 minute ago", status_text_at(1))
  end)

  it("changes the highlight of the STATUS column when the state in the store changes", function()
    store.replace_all("container", { container({ state = "running" }) })
    list.render(handle, def, store.list("container"))
    assert.are.equal("DockerStatusRunning", marks()[1][4].hl_group)

    store.upsert("container", container({ state = "exited", status = "Exited (0) 1 minute ago" }))
    list.render(handle, def, store.list("container"))

    assert.are.equal("DockerStatusExited", marks()[1][4].hl_group)
  end)

  it("applies a different highlight per row according to each state", function()
    store.replace_all("container", {
      container({ id = "1", name = "a", state = "running" }),
      container({ id = "2", name = "b", state = "paused" }),
      container({ id = "3", name = "c", state = "exited" }),
    })

    list.render(handle, def, store.list("container"))

    local groups = {}
    for _, mark in ipairs(marks()) do
      table.insert(groups, mark[4].hl_group)
    end
    assert.are.same({ "DockerStatusRunning", "DockerStatusPaused", "DockerStatusExited" }, groups)
  end)

  it("applies the highlight only within the range of the STATUS column", function()
    store.replace_all("container", { container({ name = "web", state = "running", status = "Up 5 days" }) })

    list.render(handle, def, store.list("container"))

    -- The preceding NAME column and the following PORTS column must not be caught up in it.
    assert.are.equal("Up 5 days", status_text_at(1))
  end)

  it("leaves no highlight behind once the list becomes empty", function()
    store.replace_all("container", { container({ state = "running" }) })
    list.render(handle, def, store.list("container"))

    store.replace_all("container", {})
    list.render(handle, def, store.list("container"))

    assert.are.same({}, marks())
    assert.are.same({ "No containers" }, vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false))
  end)

  it("does not stack stale highlights on re-render", function()
    store.replace_all("container", { container({ state = "running" }) })
    list.render(handle, def, store.list("container"))
    list.render(handle, def, store.list("container"))

    assert.are.equal(1, #marks())
  end)

  describe("busy display", function()
    ---@return fun(item: table): boolean
    local function busy_from_ledger()
      return function(item)
        return operations.has_any(tostring(item.id))
      end
    end

    it("shows the busy marker on the target row once an operation starts", function()
      store.replace_all("container", { container({ id = "abc123", status = "Up 5 days" }) })
      list.render(handle, def, store.list("container"), { busy = busy_from_ledger() })
      assert.is_nil(vim.api.nvim_buf_get_lines(handle.bufnr, 0, 1, false)[1]:find("(busy)", 1, true))

      operations.begin("abc123", "stop")
      list.render(handle, def, store.list("container"), { busy = busy_from_ledger() })

      assert.is_truthy(vim.api.nvim_buf_get_lines(handle.bufnr, 0, 1, false)[1]:find("(busy)", 1, true))
    end)

    it("removes the busy marker once the operation finishes", function()
      store.replace_all("container", { container({ id = "abc123" }) })
      operations.begin("abc123", "stop")
      list.render(handle, def, store.list("container"), { busy = busy_from_ledger() })

      operations.finish("abc123", "stop")
      list.render(handle, def, store.list("container"), { busy = busy_from_ledger() })

      assert.is_nil(vim.api.nvim_buf_get_lines(handle.bufnr, 0, 1, false)[1]:find("(busy)", 1, true))
    end)

    it("puts no marker on rows that are not busy", function()
      store.replace_all("container", {
        container({ id = "a", name = "busy-one" }),
        container({ id = "b", name = "idle-one" }),
      })
      operations.begin("a", "stop")

      list.render(handle, def, store.list("container"), { busy = busy_from_ledger() })

      local lines = vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)
      assert.is_truthy(lines[1]:find("(busy)", 1, true), lines[1])
      assert.is_nil(lines[2]:find("(busy)", 1, true), lines[2])
    end)

    it("puts no marker at all when no busy predicate is passed", function()
      store.replace_all("container", { container({ id = "abc123" }) })
      operations.begin("abc123", "stop")

      list.render(handle, def, store.list("container"))

      assert.is_nil(vim.api.nvim_buf_get_lines(handle.bufnr, 0, 1, false)[1]:find("(busy)", 1, true))
    end)
  end)
end)
