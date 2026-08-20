local cli = require("docker.adapters.docker.cli")
local config = require("docker.config")
local events = require("docker.adapters.docker.events")
local jobs = require("docker.handlers.jobs")
local lifecycle = require("docker.handlers.lifecycle")
local store = require("docker.state.store")

describe("filtering the list", function()
  local original_input

  before_each(function()
    config._reset()
    store._reset()
    jobs._reset()
    jobs._set_stopper(function() end)
    lifecycle.close_all()
    original_input = vim.ui.input
    cli._set_executor(function(cmd, _, on_exit)
      if cmd[2] == "version" then
        on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
        return
      end
      local rows = {}
      for _, spec in ipairs({
        { id = "1", name = "web-server", image = "nginx" },
        { id = "2", name = "database", image = "postgres" },
        { id = "3", name = "cache", image = "redis" },
      }) do
        table.insert(
          rows,
          vim.json.encode({
            id = spec.id,
            name = spec.name,
            image = spec.image,
            state = "running",
            status = "Up",
            ports = "",
            command = "x",
            created_at = "now",
            compose_project = "",
            compose_service = "",
            compose_oneoff = "",
          })
        )
      end
      on_exit({ code = 0, stdout = table.concat(rows, "\n"), stderr = "" })
    end)
    events._set_starter(function()
      return 900
    end)
    events._set_waiter(function() end)
  end)

  after_each(function()
    lifecycle.close_all()
    vim.ui.input = original_input
    cli._set_executor(nil)
    events._set_starter(nil)
    events._set_waiter(nil)
    jobs._reset()
    config._reset()
    store._reset()
  end)

  ---@return docker.ViewHandle
  local function open_view()
    local captured, called = nil, false
    lifecycle.open("container", function(handle)
      captured, called = handle, true
    end)
    assert(vim.wait(3000, function()
      return called
    end))
    return assert(captured)
  end

  ---@param text string|nil
  local function answer_filter(text)
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.input = function(_, on_confirm)
      on_confirm(text)
    end
  end

  ---@param handle docker.ViewHandle
  ---@return string[]
  local function lines(handle)
    return vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false)
  end

  it("lists every item before any filter is applied", function()
    local handle = open_view()

    assert.are.equal(3, #lines(handle))
  end)

  it("shows only the rows that match the filter as a substring", function()
    local handle = open_view()
    answer_filter("web")

    lifecycle.dispatch_for_test(handle, "filter")

    local shown = lines(handle)
    assert.are.equal(1, #shown)
    assert.is_truthy(shown[1]:find("web-server", 1, true), shown[1])
  end)

  it("matches a part of the image name that the column bound keeps off screen", function()
    -- The IMAGE column is bounded (see docker-opt-column-max-widths), so the tail of a long
    -- image name is never drawn. The filter looks at the value instead of the drawn text.
    cli._set_executor(function(cmd, _, on_exit)
      if cmd[2] == "version" then
        on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
        return
      end
      local rows = {}
      for _, spec in ipairs({
        { id = "1", name = "web-server", image = "registry.example.com/team/backend-api:v1" },
        { id = "2", name = "database", image = "postgres" },
      }) do
        table.insert(
          rows,
          vim.json.encode({
            id = spec.id,
            name = spec.name,
            image = spec.image,
            state = "running",
            status = "Up",
            ports = "",
            command = "x",
            created_at = "now",
            compose_project = "",
            compose_service = "",
            compose_oneoff = "",
          })
        )
      end
      on_exit({ code = 0, stdout = table.concat(rows, "\n"), stderr = "" })
    end)

    local handle = open_view()
    -- The name is cut after 29 columns, so "backend-api" is not part of what is drawn.
    assert.is_truthy(lines(handle)[1]:find("registry.example.com/team/bac…", 1, true), lines(handle)[1])

    answer_filter("backend-api")
    lifecycle.dispatch_for_test(handle, "filter")

    local shown = lines(handle)
    assert.are.equal(1, #shown)
    assert.is_truthy(shown[1]:find("web-server", 1, true), shown[1])
  end)

  it("matches columns other than the name as well", function()
    local handle = open_view()
    answer_filter("postgres")

    lifecycle.dispatch_for_test(handle, "filter")

    local shown = lines(handle)
    assert.are.equal(1, #shown)
    assert.is_truthy(shown[1]:find("database", 1, true), shown[1])
  end)

  it("goes back to every row when an empty string is entered", function()
    local handle = open_view()
    answer_filter("web")
    lifecycle.dispatch_for_test(handle, "filter")
    assert.are.equal(1, #lines(handle))

    answer_filter("")
    lifecycle.dispatch_for_test(handle, "filter")

    assert.are.equal(3, #lines(handle))
  end)

  it("leaves the filter unchanged when the input is cancelled", function()
    local handle = open_view()
    answer_filter("web")
    lifecycle.dispatch_for_test(handle, "filter")

    answer_filter(nil)
    lifecycle.dispatch_for_test(handle, "filter")

    assert.are.equal(1, #lines(handle))
  end)

  it("falls back to the empty display when nothing matches", function()
    local handle = open_view()
    answer_filter("zzz-no-match")

    lifecycle.dispatch_for_test(handle, "filter")

    assert.are.same({ "No containers" }, lines(handle))
  end)

  it("applies an operation to the target of the displayed row while a filter is active", function()
    -- If the rows and the items get out of sync, a different container would be operated on.
    local handle = open_view()
    answer_filter("cache")
    lifecycle.dispatch_for_test(handle, "filter")

    local runs = {}
    cli._set_executor(function(cmd, _, on_exit)
      table.insert(runs, cmd)
      on_exit({ code = 0, stdout = "", stderr = "" })
    end)
    vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 0 })
    lifecycle.dispatch_for_test(handle, "stop")

    assert.are.same({ "docker", "stop", "3" }, runs[1], "the first row after filtering (cache) must be the target")
  end)

  it("binds the filter to Ctrl-f and does not take over /", function()
    -- `/` is left as Neovim's own search.
    local handle = open_view()

    local mapped = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(handle.window.bufnr, "n")) do
      mapped[m.lhs] = true
    end

    assert.is_true(mapped["<C-F>"] or mapped["<C-f>"], "Ctrl-f must be bound")
    assert.is_nil(mapped["/"], "/ must not be bound")
  end)
end)
