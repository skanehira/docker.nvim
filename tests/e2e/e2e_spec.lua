-- G_E2E: run every use case of the MVP through against a real docker.
--
-- Preparing and cleaning up the resources used by the test is the job of scripts/e2e.sh.
-- This file sticks to "drive docker.nvim against the prepared environment and assert each
-- stage".
local docker = require("docker")
local jobs = require("docker.handlers.jobs")
local lifecycle = require("docker.handlers.lifecycle")

local PREFIX = assert(vim.env.DOCKER_NVIM_E2E_PREFIX, "must be run through scripts/e2e.sh")
--- The image used by the test. It may be passed with a tag.
local E2E_IMAGE = vim.env.DOCKER_NVIM_E2E_IMAGE or "alpine"

---@param cmd string[]
---@return string
local function sh(cmd)
  local out = vim.fn.system(cmd)
  return type(out) == "string" and out or ""
end

---@param kind string
---@return docker.ViewHandle
local function open_view(kind)
  local captured, called = nil, false
  lifecycle.open(kind, function(handle)
    captured, called = handle, true
  end)
  assert(
    vim.wait(20000, function()
      return called
    end),
    "the " .. kind .. " view did not open"
  )
  return assert(captured, "the " .. kind .. " view handle is nil")
end

---@param handle docker.ViewHandle
---@return string[]
local function rows(handle)
  return vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false)
end

---@param handle docker.ViewHandle
---@param needle string
---@return integer|nil
local function line_of(handle, needle)
  for index, line in ipairs(rows(handle)) do
    if line:find(needle, 1, true) then
      return index
    end
  end
  return nil
end

---@param handle docker.ViewHandle
---@param needle string
---@param timeout integer|nil
local function wait_for_line(handle, needle, timeout)
  assert(
    vim.wait(timeout or 15000, function()
      return line_of(handle, needle) ~= nil
    end, 100),
    ("the line never appeared: %s\n%s"):format(needle, table.concat(rows(handle), "\n"))
  )
end

--- The set of job IDs recorded in the ledger.
--- Closing a list also drops the events subscription, so the check looks at
--- "which IDs were added" instead of at the count going up or down.
---@return table<integer, boolean>
local function job_set()
  local set = {}
  for _, id in ipairs(jobs.list()) do
    set[id] = true
  end
  return set
end

--- The job IDs newly recorded in the ledger.
---@param before table<integer, boolean>
---@return integer[]
local function jobs_added_since(before)
  local added = {}
  for _, id in ipairs(jobs.list()) do
    if not before[id] then
      table.insert(added, id)
    end
  end
  return added
end

---@param handle docker.ViewHandle
---@param needle string
---@param action string
local function act_on(handle, needle, action)
  local lnum = assert(line_of(handle, needle), "the target row was not found: " .. needle)
  vim.api.nvim_set_current_win(handle.window.winid)
  vim.api.nvim_win_set_cursor(handle.window.winid, { lnum, 0 })
  lifecycle.dispatch_for_test(handle, action)
end

describe("G_E2E: end-to-end scenarios of docker.nvim", function()
  before_each(function()
    docker.setup()
  end)

  after_each(function()
    lifecycle.close_all()
  end)

  it("US-001: every container including the stopped ones is listed with the compose columns", function()
    local handle = open_view("container")

    wait_for_line(handle, PREFIX .. "-standalone")
    wait_for_line(handle, PREFIX .. "-proj-web-1")

    -- Rows coming from compose carry PROJECT / SERVICE; non-compose rows leave them blank.
    local compose_line = rows(handle)[assert(line_of(handle, PREFIX .. "-proj-web-1"))]
    assert.is_truthy(compose_line:find(PREFIX .. "-proj", 1, true), compose_line)

    local plain_line = rows(handle)[assert(line_of(handle, PREFIX .. "-standalone"))]
    assert.is_nil(plain_line:find(PREFIX .. "-proj", 1, true), plain_line)
  end)

  it("US-002: stopping and starting are reflected in STATUS", function()
    local handle = open_view("container")
    wait_for_line(handle, PREFIX .. "-standalone")

    act_on(handle, PREFIX .. "-standalone", "kill")
    assert(
      vim.wait(20000, function()
        local lnum = line_of(handle, PREFIX .. "-standalone")
        return lnum ~= nil and rows(handle)[lnum]:find("Exited", 1, true) ~= nil
      end, 100),
      "the stop is not reflected:\n" .. table.concat(rows(handle), "\n")
    )

    act_on(handle, PREFIX .. "-standalone", "start")
    assert(
      vim.wait(20000, function()
        local lnum = line_of(handle, PREFIX .. "-standalone")
        return lnum ~= nil and rows(handle)[lnum]:find("Up", 1, true) ~= nil
      end, 100),
      "the start is not reflected:\n" .. table.concat(rows(handle), "\n")
    )
  end)

  it("US-004 / G4: closing the log terminal leaves no docker logs process behind", function()
    local handle = open_view("container")
    wait_for_line(handle, PREFIX .. "-standalone")
    local before = job_set()

    act_on(handle, PREFIX .. "-standalone", "logs")
    assert(
      vim.wait(10000, function()
        return jobs_added_since(before)[1] ~= nil
      end),
      "the terminal job is not registered"
    )

    -- Focus moves to the terminal, so the float of the list does not stay open.
    assert.is_nil(lifecycle.get("container"), "the list must be closed")
    assert.is_false(vim.api.nvim_win_is_valid(handle.window.winid))

    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_delete(bufnr, { force = true })

    assert(
      vim.wait(10000, function()
        return #jobs_added_since(before) == 0
      end),
      ("the job is not removed from the ledger (remaining jobs: %s)"):format(vim.inspect(jobs_added_since(before)))
    )
    assert(
      vim.wait(10000, function()
        return sh({ "sh", "-c", "pgrep -f 'docker logs -f' || true" }):match("%S") == nil
      end, 200),
      "a docker logs process is still alive"
    )
  end)

  it("US-003 / G3: a container can be deleted after a confirmation", function()
    local handle = open_view("container")
    wait_for_line(handle, PREFIX .. "-doomed")

    -- A running container is never force-removed (BR-002), so stop it before deleting it.
    act_on(handle, PREFIX .. "-doomed", "kill")
    assert(
      vim.wait(20000, function()
        local lnum = line_of(handle, PREFIX .. "-doomed")
        return lnum ~= nil and rows(handle)[lnum]:find("Exited", 1, true) ~= nil
      end, 100),
      "the stop is not reflected"
    )

    -- Anything other than y does not delete
    vim.ui.input = function(_, on_confirm)
      on_confirm("n")
    end
    act_on(handle, PREFIX .. "-doomed", "delete")
    vim.wait(1500)
    assert.is_truthy(line_of(handle, PREFIX .. "-doomed"), "n must not delete it")

    vim.ui.input = function(_, on_confirm)
      on_confirm("y")
    end
    act_on(handle, PREFIX .. "-doomed", "delete")
    assert(
      vim.wait(20000, function()
        return line_of(handle, PREFIX .. "-doomed") == nil
      end, 100),
      "the deletion is not reflected in the list"
    )
  end)

  it("US-006 / G5: opening and closing the detail view restores the cursor position", function()
    local handle = open_view("container")
    wait_for_line(handle, PREFIX .. "-standalone")
    local lnum = assert(line_of(handle, PREFIX .. "-standalone"))

    vim.api.nvim_set_current_win(handle.window.winid)
    vim.api.nvim_win_set_cursor(handle.window.winid, { lnum, 0 })
    lifecycle.dispatch_for_test(handle, "inspect")
    assert(
      vim.wait(15000, function()
        return vim.api.nvim_get_current_win() ~= handle.window.winid
      end),
      "the detail view does not open"
    )

    local detail = vim.api.nvim_get_current_win()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "x", false)

    assert.is_false(vim.api.nvim_win_is_valid(detail), "the detail must be closed")
    assert.are.equal(lnum, vim.api.nvim_win_get_cursor(handle.window.winid)[1], "the cursor must be restored")
  end)

  it("US-011 / G9: an action from another process reaches the list within 1 second", function()
    local handle = open_view("container")
    wait_for_line(handle, PREFIX .. "-standalone")

    local name = PREFIX .. "-live"
    sh({ "docker", "run", "-d", "--name", name, E2E_IMAGE, "sleep", "300" })

    local start = vim.fn.reltime()
    assert(
      vim.wait(5000, function()
        return line_of(handle, name) ~= nil
      end, 20),
      "the start from another process is not reflected"
    )
    local elapsed_ms = vim.fn.reltimefloat(vim.fn.reltime(start)) * 1000

    assert.is_true(elapsed_ms < 1000, ("took %.0fms to be reflected (target is within 1000ms)"):format(elapsed_ms))
    sh({ "docker", "rm", "-f", name })
  end)

  it("US-012 / G10: R re-fetches the list", function()
    local handle = open_view("container")
    wait_for_line(handle, PREFIX .. "-standalone")

    -- If R did nothing, the mere fact that "the list is still there" would pass.
    -- A container created from another process showing up after R proves the re-fetch.
    local name = PREFIX .. "-refresh"
    sh({ "docker", "create", "--name", name, E2E_IMAGE, "true" })
    -- Stop the subscription before pressing R, to tell this apart from the automatic
    -- update driven by events.
    assert(handle.subscription, "a subscription must be in place").stop()
    vim.wait(300)
    assert.is_nil(line_of(handle, name), "it must not appear on its own once the subscription is stopped")

    lifecycle.dispatch_for_test(handle, "refresh")

    assert(
      vim.wait(15000, function()
        return line_of(handle, name) ~= nil
      end, 100),
      "it must appear in the list re-fetched by R"
    )
    sh({ "docker", "rm", "-f", name })
  end)

  it("US-015 / G12: ? lists the keys available in that view", function()
    local handle = open_view("container")

    lifecycle.dispatch_for_test(handle, "help")
    assert(
      vim.wait(5000, function()
        return vim.api.nvim_get_current_win() ~= handle.window.winid
      end),
      "the help does not open"
    )

    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(text:find("start", 1, true), text)
    assert.is_truthy(text:find("logs", 1, true), text)
    -- Actions that the container list does not have are not listed
    assert.is_nil(text:find("quickrun", 1, true), text)
  end)

  it("US-007 / G6: images / volumes / networks are listed", function()
    local volumes = open_view("volume")
    wait_for_line(volumes, PREFIX .. "-vol")
    lifecycle.close("volume")

    local networks = open_view("network")
    wait_for_line(networks, PREFIX .. "-net")
    lifecycle.close("network")

    local images = open_view("image")
    -- Even with 0 entries the single line of empty_text comes back, so the count alone
    -- does not verify anything.
    local image_rows = rows(images)
    assert.is_nil(
      image_rows[1]:find("イメージがありません", 1, true),
      "real data must be listed: " .. image_rows[1]
    )
    -- The image list keeps REPOSITORY and TAG in separate columns, so search by the name
    -- with the tag stripped off.
    wait_for_line(images, (E2E_IMAGE:gsub(":.*$", "")))
  end)

  it("US-007: an image can be deleted", function()
    -- Tag it under another name for the test and delete that one (the original image stays).
    local tag = PREFIX .. "-img:v1"
    sh({ "docker", "tag", E2E_IMAGE, tag })

    local handle = open_view("image")
    wait_for_line(handle, PREFIX .. "-img")

    vim.ui.input = function(_, on_confirm)
      on_confirm("y")
    end
    act_on(handle, PREFIX .. "-img", "delete")

    assert(
      vim.wait(20000, function()
        return line_of(handle, PREFIX .. "-img") == nil
      end, 100),
      "the deletion is not reflected in the list"
    )
  end)

  it("US-008 / US-009 / G7 / G8: the service list and compose actions from outside the project", function()
    -- Open from a place that has no compose file. The location of a project is derived
    -- from the labels of its containers, so every project shows up in the list.
    vim.cmd("cd " .. vim.fn.fnameescape(vim.env.HOME or "/"))
    local handle = open_view("service")

    -- The two projects are listed with the PROJECT column
    wait_for_line(handle, PREFIX .. "-proj2")
    wait_for_line(handle, PREFIX .. "-proj ")

    -- A service that was never started is listed as none too, from the definition looked
    -- up through the labels
    wait_for_line(handle, "never-started")
    local none_line = rows(handle)[assert(line_of(handle, "never-started"))]
    assert.is_truthy(none_line:find("none", 1, true), none_line)

    -- Starting a single service is reflected (the row carries the location of the compose file)
    act_on(handle, "never-started", "up")
    assert(
      vim.wait(60000, function()
        local lnum = line_of(handle, "never-started")
        return lnum ~= nil and rows(handle)[lnum]:find("running", 1, true) ~= nil
      end, 200),
      "the start of the service is not reflected:\n" .. table.concat(rows(handle), "\n")
    )
  end)

  it("US-010: D tears down only the project of the row", function()
    vim.cmd("cd " .. vim.fn.fnameescape(vim.env.HOME or "/"))
    local handle = open_view("service")
    wait_for_line(handle, "web")
    wait_for_line(handle, "api")

    vim.ui.input = function(_, on_confirm)
      on_confirm("y")
    end
    act_on(handle, "web", "project_down")

    -- The services of the torn-down project disappear from the list (the place their
    -- definition is looked up from is gone as well).
    assert(
      vim.wait(60000, function()
        return line_of(handle, PREFIX .. "-proj ") == nil
      end, 200),
      "the teardown is not reflected:\n" .. table.concat(rows(handle), "\n")
    )

    -- The other project is not caught in the blast.
    local api_line = rows(handle)[assert(line_of(handle, "api"), table.concat(rows(handle), "\n"))]
    assert.is_truthy(api_line:find("running", 1, true), api_line)
  end)

  it("US-013: Neovim does not block while docker is running", function()
    local cli = require("docker.adapters.docker.cli")

    -- Fire a docker run that really takes time and check that control comes back before it
    -- returns. Were it synchronous, it would already be finished at this assert.
    local finished = false
    cli.run({ "run", "--rm", E2E_IMAGE, "sleep", "2" }, function()
      finished = true
    end)

    assert.is_false(finished, "it must not be finished when the call returns (it must be asynchronous)")

    -- Another buffer can be edited while it runs
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "editable" })
    assert.are.same({ "editable" }, vim.api.nvim_buf_get_lines(scratch, 0, -1, false))
    vim.api.nvim_buf_delete(scratch, { force = true })

    assert(
      vim.wait(20000, function()
        return finished
      end, 100),
      "it must finish eventually"
    )
  end)

  it("US-005: a shell can be opened / it does not open for a stopped container", function()
    local handle = open_view("container")
    wait_for_line(handle, PREFIX .. "-standalone")
    local jobs_before = job_set()

    act_on(handle, PREFIX .. "-standalone", "shell")
    assert(
      vim.wait(10000, function()
        return jobs_added_since(jobs_before)[1] ~= nil
      end),
      "a shell must open for a running container"
    )
    vim.api.nvim_buf_delete(vim.api.nvim_get_current_buf(), { force = true })
    vim.wait(500)

    -- It does not open for a stopped container (BR-007)
    local stopped = PREFIX .. "-stopped"
    sh({ "docker", "create", "--name", stopped, E2E_IMAGE, "true" })
    -- The list closed the moment focus moved to the shell, so open it again.
    handle = open_view("container")
    wait_for_line(handle, stopped)

    local before = job_set()
    act_on(handle, stopped, "shell")
    vim.wait(1500)

    assert.are.same({}, jobs_added_since(before), "no shell must open for a stopped container")
    sh({ "docker", "rm", "-f", stopped })
  end)

  it("G13: running the shutdown with views still open leaves no child process behind", function()
    local handle = open_view("container")
    wait_for_line(handle, PREFIX .. "-standalone")
    act_on(handle, PREFIX .. "-standalone", "logs")
    vim.wait(2000)
    assert.is_true(#jobs.list() > 0, "a job must be registered")

    -- The cleanup that VimLeavePre performs
    jobs.stop_all()

    assert.are.same({}, jobs.list())
    assert(
      vim.wait(10000, function()
        return sh({ "sh", "-c", "pgrep -f 'docker logs -f' || true" }):match("%S") == nil
      end, 200),
      "a docker logs process is still alive after the shutdown"
    )
  end)
end)
