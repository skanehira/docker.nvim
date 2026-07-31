local cli = require("docker.adapters.docker.cli")
local file_edit = require("docker.handlers.file_edit")
local window = require("docker.ui.window")

describe("docker.handlers.file_edit", function()
  local runs, notified
  local original_notify
  local opened_buffers

  --- A fake docker that intercepts `docker cp` and writes the contents out on the pull side.
  ---@param opts { fail_pull: boolean|nil, fail_push: boolean|nil, contents: string[]|nil }
  local function stub(opts)
    cli._set_executor(function(cmd, _, on_exit)
      table.insert(runs, cmd)
      local source, destination = cmd[3], cmd[4]
      local pulling = source:find(":", 1, true) ~= nil
      if pulling then
        if opts.fail_pull then
          on_exit({ code = 1, stdout = "", stderr = "Error: No such container:path" })
          return
        end
        vim.fn.writefile(opts.contents or { "hello" }, destination)
        on_exit({ code = 0, stdout = "", stderr = "" })
        return
      end
      if opts.fail_push then
        on_exit({ code = 1, stdout = "", stderr = "Error: permission denied" })
        return
      end
      on_exit({ code = 0, stdout = "", stderr = "" })
    end)
  end

  ---@return integer|nil
  local function open(id, label, path)
    local captured, called = nil, false
    file_edit.open(id, label, path, function(bufnr)
      captured, called = bufnr, true
    end)
    assert(vim.wait(3000, function()
      return called
    end))
    if captured then
      table.insert(opened_buffers, captured)
    end
    return captured
  end

  before_each(function()
    runs, notified, opened_buffers = {}, {}, {}
    file_edit._reset()
    original_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end
  end)

  after_each(function()
    for _, bufnr in ipairs(opened_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    -- Clean up the opened windows. Letting them accumulate piles splits up and
    -- at some point opening fails with E36 (Not enough room).
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if #vim.api.nvim_tabpage_list_wins(0) > 1 then
        pcall(vim.api.nvim_win_close, winid, true)
      end
    end
    vim.notify = original_notify
    cli._set_executor(nil)
    file_edit._reset()
  end)

  describe("open", function()
    it("pulls the file out of the container", function()
      stub({})

      open("abc123", "web", "/etc/hosts")

      assert.are.equal("docker", runs[1][1])
      assert.are.equal("cp", runs[1][2])
      assert.are.equal("abc123:/etc/hosts", runs[1][3])
    end)

    it("gives the buffer a name in the docker scheme", function()
      stub({})

      local bufnr = assert(open("abc123", "web", "/etc/hosts"))

      assert.are.equal("docker://web/etc/hosts", vim.fn.bufname(bufnr))
    end)

    it("loads the pulled contents into the buffer", function()
      stub({ contents = { "line1", "line2" } })

      local bufnr = assert(open("abc123", "web", "/etc/hosts"))

      assert.are.same({ "line1", "line2" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      assert.is_false(vim.bo[bufnr].modified, "must be unmodified right after opening")
    end)

    it("puts a per-container identifier into the temporary file name", function()
      -- If the name were the path alone, the same path in another container would mix the contents up.
      local pulled = {}
      cli._set_executor(function(cmd, _, on_exit)
        table.insert(pulled, cmd[4])
        vim.fn.writefile({ "x" }, cmd[4])
        on_exit({ code = 0, stdout = "", stderr = "" })
      end)

      open("aaaaaaaaaaaa", "web", "/etc/hosts")
      open("bbbbbbbbbbbb", "db", "/etc/hosts")

      assert.are.equal(2, #pulled)
      assert.is_true(pulled[1] ~= pulled[2], "the temporary file names must differ: " .. pulled[1])
    end)

    it("does not mix up the write-back destinations when the same path is opened in another container", function()
      stub({})
      local first = assert(open("aaaaaaaaaaaa", "web", "/etc/hosts"))
      local second = assert(open("bbbbbbbbbbbb", "db", "/etc/hosts"))

      assert.is_true(first ~= second, "must be a different buffer")

      runs = {}
      vim.api.nvim_buf_set_lines(second, 0, -1, false, { "changed" })
      file_edit.write(second)
      assert(vim.wait(2000, function()
        return #runs > 0
      end))

      assert.are.equal("bbbbbbbbbbbb:/etc/hosts", runs[1][4], "must write back to the second container")
    end)

    it("does not grab another buffer whose name merely shares the prefix", function()
      -- Using pattern matching to look a buffer up by name would mistake
      -- docker://web/etc/hosts.orig, which the user had open, for "the same file"
      -- and overwrite it with the container's contents.
      stub({ contents = { "container contents" } })
      local other = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(other, "docker://web/etc/hosts.orig")
      vim.api.nvim_buf_set_lines(other, 0, -1, false, { "user contents" })

      local bufnr = assert(open("abc123", "web", "/etc/hosts"))

      assert.is_true(bufnr ~= other, "must use a different buffer")
      assert.are.same({ "user contents" }, vim.api.nvim_buf_get_lines(other, 0, -1, false))
      vim.api.nvim_buf_delete(other, { force = true })
    end)

    it("neither opens a buffer nor keeps the pulled contents when a directory is given", function()
      -- Given a directory, `docker cp` pulls the whole thing down. Passing that straight to
      -- readfile raises, and the pulled contents stay in the cache forever.
      local pulled
      cli._set_executor(function(cmd, _, on_exit)
        table.insert(runs, cmd)
        pulled = cmd[4]
        vim.fn.mkdir(pulled .. "/sub", "p")
        vim.fn.writefile({ "x" }, pulled .. "/sub/file")
        on_exit({ code = 0, stdout = "", stderr = "" })
      end)

      local bufnr = open("abc123", "web", "/etc")

      assert.is_nil(bufnr, "must not open a buffer")
      assert.are.same(
        { msg = "/etc is a directory, so it cannot be edited", level = vim.log.levels.ERROR },
        notified[#notified]
      )
      assert.are.equal(0, vim.fn.isdirectory(pulled), "must not keep the pulled contents: " .. tostring(pulled))
    end)

    it("does not open a buffer when the pull fails", function()
      stub({ fail_pull = true })

      local bufnr = open("abc123", "web", "/nope")

      assert.is_nil(bufnr)
      assert.are.equal(vim.log.levels.ERROR, notified[#notified].level)
    end)

    it("does not steal the buffer of the focused float", function()
      -- Swapping the buffer while the float has focus wipes out the list buffer, which is
      -- bufhidden=wipe, leaving only the float alive so the list is never drawn again.
      stub({})
      local float = window.open({ title = "Containers" })
      window.set_lines(float, { "web  alpine" })

      open("abc123", "web", "/etc/hosts")

      assert.is_true(vim.api.nvim_buf_is_valid(float.bufnr), "the list buffer must stay alive")
      assert.are.same({ "web  alpine" }, vim.api.nvim_buf_get_lines(float.bufnr, 0, -1, false))
      window.close(float)
    end)

    it("opens in a window separate from the float", function()
      stub({})
      local float = window.open({ title = "Containers" })

      local bufnr = assert(open("abc123", "web", "/etc/hosts"))

      local winid = vim.api.nvim_get_current_win()
      assert.is_true(winid ~= float.winid, "must be a window separate from the float")
      assert.are.equal(bufnr, vim.api.nvim_win_get_buf(winid), "the opened buffer must be displayed")
      window.close(float)
    end)

    it("returns to the same window for a file that is already open", function()
      -- Adding a split on every open piles up window after window for the same file.
      stub({})
      local bufnr = assert(open("abc123", "web", "/etc/hosts"))
      local first_win = vim.api.nvim_get_current_win()
      local windows_before = #vim.api.nvim_tabpage_list_wins(0)

      assert.are.equal(bufnr, open("abc123", "web", "/etc/hosts"))

      assert.are.equal(first_win, vim.api.nvim_get_current_win(), "must return to the same window")
      assert.are.equal(windows_before, #vim.api.nvim_tabpage_list_wins(0), "must not add a window")
    end)

    it("gives the buffer a type that intercepts saving", function()
      stub({})

      local bufnr = assert(open("abc123", "web", "/etc/hosts"))

      assert.are.equal("acwrite", vim.bo[bufnr].buftype)
    end)
  end)

  describe("buffer cleanup", function()
    it("runs the write back only once even when the same file is opened twice", function()
      -- Attaching BufWriteCmd again on every open makes a single save run docker cp
      -- several times and emit just as many notifications.
      stub({})
      local bufnr = assert(open("abc123", "web", "/etc/hosts"))
      assert.are.equal(bufnr, open("abc123", "web", "/etc/hosts"), "must reuse the same buffer")
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "changed" })
      runs = {}

      vim.cmd("silent write")
      vim.wait(1000, function()
        return #runs > 1
      end)

      assert.are.equal(1, #runs, "the write back must run only once")
    end)

    it("detaches the write-back mapping when the buffer is closed", function()
      -- `:bdelete` releases the buffer while keeping its number, so looking at the number
      -- alone would still allow writing back after it was closed.
      stub({})
      local bufnr = assert(open("abc123", "web", "/etc/hosts"))
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "changed" })
      runs = {}

      file_edit.write(bufnr)
      assert(vim.wait(2000, function()
        return #runs > 0
      end))
      assert.are.equal("abc123:/etc/hosts", runs[1][4], "must be able to write back before closing")

      vim.cmd(("silent %dbdelete!"):format(bufnr))
      runs = {}
      file_edit.write(bufnr)
      vim.wait(500, function()
        return #runs > 0
      end)

      assert.are.same({}, runs, "must not write back after closing")
    end)

    it("runs the write back only once when a closed buffer is reopened", function()
      -- With `:bdelete` the buffer number survives, so reopening grabs the same number.
      -- Unless the cleanup releases the interception, BufWriteCmd is attached twice.
      stub({})
      local first = assert(open("abc123", "web", "/etc/hosts"))
      vim.cmd(("silent %dbdelete!"):format(first))

      local second = assert(open("abc123", "web", "/etc/hosts"))
      vim.api.nvim_buf_set_lines(second, 0, -1, false, { "changed" })
      runs = {}

      vim.cmd("silent write")
      vim.wait(1000, function()
        return #runs > 1
      end)

      assert.are.equal(1, #runs, "the write back must run only once")
    end)

    it("deletes the temporary file as well when the buffer is wiped out", function()
      -- If the pulled contents kept piling up in the cache, the container's contents would
      -- accumulate on the host side.
      local pulled
      cli._set_executor(function(cmd, _, on_exit)
        table.insert(runs, cmd)
        pulled = cmd[4]
        vim.fn.writefile({ "hello" }, pulled)
        on_exit({ code = 0, stdout = "", stderr = "" })
      end)
      local bufnr = assert(open("abc123", "web", "/etc/hosts"))
      assert.are.equal(1, vim.fn.filereadable(pulled), "must exist at the moment it is pulled")

      vim.api.nvim_buf_delete(bufnr, { force = true })

      assert.are.equal(0, vim.fn.filereadable(pulled), "must be deleted once wiped out: " .. tostring(pulled))
    end)
  end)

  describe("saving", function()
    it("writes back to the container on write", function()
      stub({})
      local bufnr = assert(open("abc123", "web", "/etc/hosts"))
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "changed" })
      runs = {}

      file_edit.write(bufnr)
      assert(vim.wait(2000, function()
        return #runs > 0
      end))

      assert.are.equal("abc123:/etc/hosts", runs[1][4])
    end)

    it("becomes unmodified when the write back succeeds", function()
      stub({})
      local bufnr = assert(open("abc123", "web", "/etc/hosts"))
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "changed" })
      assert.is_true(vim.bo[bufnr].modified)

      file_edit.write(bufnr)
      assert(vim.wait(2000, function()
        return not vim.bo[bufnr].modified
      end))

      assert.is_false(vim.bo[bufnr].modified)
    end)

    it("keeps the changes when the write back fails", function()
      -- Clearing modified would make it look saved even though the write back did not happen.
      stub({ fail_push = true })
      local bufnr = assert(open("abc123", "web", "/etc/hosts"))
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "changed" })

      file_edit.write(bufnr)
      assert(vim.wait(2000, function()
        return #notified > 0 and notified[#notified].level == vim.log.levels.ERROR
      end))

      assert.is_true(vim.bo[bufnr].modified, "the change must remain")
    end)

    it("runs the write back on the write command", function()
      -- Checks with :write that the BufWriteCmd interception is actually in effect.
      -- The window opened by open has focus, so :write can be issued as is.
      stub({})
      local bufnr = assert(open("abc123", "web", "/etc/hosts"))
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "changed" })
      runs = {}

      vim.cmd("silent write")
      assert(vim.wait(2000, function()
        return #runs > 0
      end))

      assert.are.equal("abc123:/etc/hosts", runs[1][4])
    end)
  end)
end)
