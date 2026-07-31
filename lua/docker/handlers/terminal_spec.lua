local jobs = require("docker.handlers.jobs")
local terminal = require("docker.handlers.terminal")
local window = require("docker.ui.window")

describe("docker.handlers.terminal", function()
  local started
  local next_job_id

  before_each(function()
    jobs._reset()
    jobs._set_stopper(function() end)
    started = {}
    next_job_id = 100
    -- Only the job start is replaced; setting up the window and buffer goes through the production path
    -- (replacing all of it would let a defect that actually breaks the list slip past the tests).
    terminal._set_job_starter(function(cmd)
      table.insert(started, cmd)
      next_job_id = next_job_id + 1
      return next_job_id
    end)
  end)

  after_each(function()
    terminal._set_job_starter(nil)
    jobs._reset()
    -- Clean up the windows opened for terminals during the test
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if #vim.api.nvim_tabpage_list_wins(0) > 1 then
        pcall(vim.api.nvim_win_close, winid, true)
      end
    end
  end)

  describe("docker arguments issued", function()
    it("following logs becomes docker logs with the -f option", function()
      terminal.open_logs("abc123", "web")

      assert.are.same({ "docker", "logs", "-f", "abc123" }, started[1])
    end)

    it("opening a shell uses bash when it exists and falls back to sh otherwise", function()
      -- BR-019: a container does not necessarily have bash.
      terminal.open_shell("abc123", "web")

      local cmd = started[1]
      assert.are.same({ "docker", "exec", "-it", "abc123", "sh", "-c" }, { unpack(cmd, 1, 6) })
      local snippet = cmd[7]
      assert.is_truthy(snippet:find("exec bash", 1, true), "must try bash: " .. snippet)
      assert.is_truthy(snippet:find("exec sh", 1, true), "must fall back to sh when bash is absent: " .. snippet)
    end)

    it("command execution passes the given command through unchanged", function()
      terminal.open_exec("abc123", "web", "ls -la /etc")

      assert.are.same({ "docker", "exec", "-it", "abc123", "ls", "-la", "/etc" }, started[1])
    end)

    it("passes a quoted argument as a single word", function()
      -- If `sh -c 'echo hello world'` were split into 3 words, a different command than intended would run.
      terminal.open_exec("abc123", "web", "sh -c 'echo hello world'")

      assert.are.same({ "docker", "exec", "-it", "abc123", "sh", "-c", "echo hello world" }, started[1])
    end)

    it("strips the surrounding whitespace", function()
      terminal.open_exec("abc123", "web", "  env   -i  ")

      assert.are.same({ "docker", "exec", "-it", "abc123", "env", "-i" }, started[1])
    end)
  end)

  describe("window handling", function()
    it("does not steal the buffer of the focused float", function()
      -- Running `enew` while the float has focus wipes out the list buffer, which is
      -- bufhidden=wipe, and the list can never be opened again.
      -- Closing the list itself is lifecycle's job and is not handled here.
      local float = window.open({ title = "Containers" })
      window.set_lines(float, { "web  alpine" })

      terminal.open_logs("abc123", "web")

      assert.is_true(vim.api.nvim_buf_is_valid(float.bufnr), "the list buffer must stay alive")
      assert.are.same({ "web  alpine" }, vim.api.nvim_buf_get_lines(float.bufnr, 0, -1, false))
      window.close(float)
    end)

    it("opens in a window separate from the list float", function()
      local float = window.open({ title = "Containers" })

      local handle = terminal.open_logs("abc123", "web")

      assert.is_true(handle.bufnr ~= float.bufnr)
      window.close(float)
    end)
  end)

  describe("job ledger", function()
    it("puts the job of a started terminal on the ledger", function()
      terminal.open_logs("abc123", "web")

      assert.are.same({ 101 }, jobs.list())
    end)

    it("puts both on the ledger when a second terminal is opened for the same container", function()
      -- A buffer name collision raises E95, which drops an already started job from the
      -- ledger (a child process is left behind after :qa).
      terminal.open_logs("abc123", "web")
      terminal.open_logs("abc123", "web")

      assert.are.same({ 101, 102 }, jobs.list())
    end)

    it("disappears from the ledger when the buffer is wiped out", function()
      -- G4: verified through the real autocmd rather than a test-only entry point.
      local handle = terminal.open_logs("abc123", "web")

      vim.api.nvim_buf_delete(handle.bufnr, { force = true })

      assert.are.same({}, jobs.list())
    end)

    it("removes only the corresponding job when a buffer is wiped out", function()
      local first = terminal.open_logs("abc123", "web")
      terminal.open_shell("def456", "db")

      vim.api.nvim_buf_delete(first.bufnr, { force = true })

      assert.are.same({ 102 }, jobs.list())
    end)

    it("does not put it on the ledger when the job fails to start", function()
      terminal._set_job_starter(function()
        return 0
      end)

      terminal.open_logs("abc123", "web")

      assert.are.same({}, jobs.list())
    end)
  end)

  describe("return value", function()
    it("returns the buffer number and the job ID", function()
      local handle = terminal.open_logs("abc123", "web")

      assert.are.equal(101, handle.job_id)
      assert.is_true(type(handle.bufnr) == "number")
    end)
  end)
end)
