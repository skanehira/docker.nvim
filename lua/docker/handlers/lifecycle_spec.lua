local cli = require("docker.adapters.docker.cli")
local config = require("docker.config")
local lifecycle = require("docker.handlers.lifecycle")
local operations = require("docker.handlers.operations")
local store = require("docker.state.store")

describe("docker.handlers.lifecycle", function()
  local notified
  local original_notify

  --- A fake docker that answers both the connection check and the list fetch.
  local function fake_docker(cmd, _, on_exit)
    if cmd[2] == "version" then
      on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
    else
      on_exit({
        code = 0,
        stderr = "",
        stdout = '{"id":"abc123","name":"web","image":"alpine","state":"running","status":"Up 5 days",'
          .. '"ports":"","command":"sleep","created_at":"now","compose_project":"",'
          .. '"compose_service":"","compose_oneoff":""}\n',
      })
    end
  end

  before_each(function()
    notified = {}
    config._reset()
    store._reset()
    operations._reset()
    lifecycle.close_all()
    original_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end
    cli._set_executor(fake_docker)
  end)

  --- Wait until the view has finished opening (the connection check against docker is asynchronous).
  ---@param kind string
  ---@return docker.ViewHandle|nil
  local function open_view(kind)
    local captured, called = nil, false
    lifecycle.open(kind, function(handle)
      captured, called = handle, true
    end)
    assert(
      vim.wait(3000, function()
        return called
      end),
      "the open callback was never called"
    )
    return captured
  end

  after_each(function()
    lifecycle.close_all()
    vim.notify = original_notify
    cli._set_executor(nil)
    config._reset()
    store._reset()
  end)

  describe("open", function()
    it("opens the list view", function()
      local handle = assert(open_view("container"))
      assert.is_true(vim.api.nvim_win_is_valid(handle.window.winid))
    end)

    it("renders the fetched contents into the buffer", function()
      local handle = assert(open_view("container"))

      local lines = vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false)
      assert.is_truthy(lines[1]:find("web", 1, true), lines[1])
    end)

    it("does not end up with two floats of the same kind when closed before the open finishes", function()
      -- If close_all runs while waiting for the answer, requests are accepted again, so the
      -- second answer opens one more float and leaves an orphan that cannot be closed.
      local replies = {}
      cli._set_executor(function(cmd, _, on_exit)
        table.insert(replies, function()
          if cmd[2] == "version" then
            on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
          else
            on_exit({ code = 0, stdout = "", stderr = "" })
          end
        end)
      end)

      local before = #vim.api.nvim_list_wins()
      lifecycle.open("container")
      lifecycle.close_all()
      lifecycle.open("container")
      for _, reply in ipairs(replies) do
        reply()
      end
      vim.wait(200)

      local opened = #vim.api.nvim_list_wins() - before
      assert.are.equal(1, opened, ("exactly 1 float should stay open (actually %d)"):format(opened))
    end)

    it("moves to the existing buffer instead of creating a new one when the same kind is reopened", function()
      -- US-026: keep a single buffer even when opened across multiple tabs.
      local first = assert(open_view("container"))

      local second = assert(open_view("container"))

      assert.are.equal(first.window.bufnr, second.window.bufnr)
    end)

    it("sets the keymaps buffer-locally", function()
      -- BR-014: the plugin's keys do not take effect in buffers other than the list views.
      local handle = assert(open_view("container"))

      local mapped = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(handle.window.bufnr, "n")) do
        mapped[m.lhs] = true
      end
      assert.is_true(mapped["u"], "the key for start should be mapped")
      assert.is_true(mapped["s"], "the key for stop should be mapped")
      assert.is_true(mapped["l"], "the key for expanding a project should be mapped")
      assert.is_true(mapped["h"], "the key for collapsing a project should be mapped")
      assert.is_true(mapped["q"], "the key for close should be mapped")
    end)

    it("does not set the plugin keys on other buffers", function()
      open_view("container")

      local scratch = vim.api.nvim_create_buf(false, true)
      assert.are.same({}, vim.api.nvim_buf_get_keymap(scratch, "n"))
      vim.api.nvim_buf_delete(scratch, { force = true })
    end)

    it("warns without opening anything for an unknown kind", function()
      local handle = open_view("nonexistent")

      assert.is_nil(handle)
      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
    end)

    it("notifies an error without opening the view when docker cannot be reached", function()
      cli._set_executor(function(_, _, on_exit)
        on_exit({ code = 1, stdout = "", stderr = "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" })
      end)

      local handle = open_view("container")

      assert.is_nil(handle)
      local last = notified[#notified]
      assert.are.equal(vim.log.levels.ERROR, last.level)
      assert.is_truthy(last.msg:find("daemon", 1, true), last.msg)
    end)
  end)

  describe("column alignment of the list", function()
    --- The header as it actually appears on screen.
    ---@param handle docker.ViewHandle
    ---@return string
    local function rendered_winbar(handle)
      return vim.api.nvim_eval_statusline(vim.wo[handle.window.winid].winbar, {
        winid = handle.window.winid,
        maxwidth = vim.api.nvim_win_get_width(handle.window.winid),
        use_winbar = true,
      }).str
    end

    it("keeps the screen line count equal to the data row count even for long rows", function()
      -- With wrapping, one row becomes two screen lines, and the rows after it shift down and
      -- stop corresponding to the header.
      cli._set_executor(function(cmd, opts, on_exit)
        if cmd[2] == "ps" then
          on_exit({
            code = 0,
            stderr = "",
            stdout = vim.json.encode({
              id = "abc123",
              name = "web",
              image = "alpine",
              state = "running",
              status = "Up 5 days",
              ports = string.rep("0.0.0.0:5001->5000/tcp, ", 20),
              command = "sleep",
              created_at = "now",
              compose_project = "",
              compose_service = "",
              compose_oneoff = "",
            })
              .. "\n"
              .. '{"id":"def456","name":"db","image":"postgres","state":"running","status":"Up 1 day",'
              .. '"ports":"","command":"sleep","created_at":"now","compose_project":"",'
              .. '"compose_service":"","compose_oneoff":""}\n',
          })
          return
        end
        fake_docker(cmd, opts, on_exit)
      end)

      local handle = assert(open_view("container"))

      local buffer_lines = vim.api.nvim_buf_line_count(handle.window.bufnr)
      assert.are.equal(2, buffer_lines, "2 rows should be listed")
      assert.are.equal(buffer_lines, vim.api.nvim_win_text_height(handle.window.winid, {}).all)
    end)

    it("defines the header highlight when the list is opened", function()
      -- The winbar silently ignores a reference to an undefined group, so forgetting to call
      -- the definition leaves it uncolored without anyone noticing.
      open_view("container")

      assert.are.equal(1, vim.fn.hlexists("DockerHeader"))
    end)

    it("moves the header together with the content when scrolling horizontally", function()
      local handle = assert(open_view("container"))
      local before = rendered_winbar(handle)
      assert.are.equal("NAME", before:sub(1, 4), before)

      vim.api.nvim_win_call(handle.window.winid, function()
        vim.fn.winrestview({ leftcol = 6 })
      end)
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.window.bufnr })

      local after = rendered_winbar(handle)
      assert.are.equal(before:sub(7, 10), after:sub(1, 4), ("before=%s after=%s"):format(before, after))
    end)
  end)

  describe("close", function()
    it("closes the view", function()
      local handle = assert(open_view("container"))

      lifecycle.close("container")

      assert.is_false(vim.api.nvim_win_is_valid(handle.window.winid))
    end)

    it("uses a new buffer when opened again after being closed", function()
      local first = assert(open_view("container"))
      lifecycle.close("container")

      local second = assert(open_view("container"))

      assert.is_true(first.window.bufnr ~= second.window.bufnr)
    end)

    it("does not error when closing a kind that is not open", function()
      lifecycle.close("container")
    end)
  end)

  describe("close_all", function()
    it("closes every open view", function()
      local handle = assert(open_view("container"))

      lifecycle.close_all()

      assert.is_false(vim.api.nvim_win_is_valid(handle.window.winid))
    end)
  end)

  describe("when focus leaves the list", function()
    --- Create a plain window below and move into it.
    ---@return integer
    local function enter_plain_window()
      vim.cmd("botright new")
      return vim.api.nvim_get_current_win()
    end

    after_each(function()
      -- Clean up the plain windows created by the tests.
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if #vim.api.nvim_tabpage_list_wins(0) > 1 then
          pcall(vim.api.nvim_win_close, winid, true)
        end
      end
    end)

    describe("switching tabs", function()
      local terminal = require("docker.handlers.terminal")
      local original_tabpage

      before_each(function()
        original_tabpage = vim.api.nvim_get_current_tabpage()
        terminal._set_job_starter(function()
          return 101
        end)
      end)

      after_each(function()
        lifecycle.close_all()
        terminal._set_job_starter(nil)
        require("docker.handlers.jobs")._reset()
        for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
          if tabpage ~= original_tabpage then
            vim.cmd("tabclose! " .. vim.api.nvim_tabpage_get_number(tabpage))
          end
        end
        vim.api.nvim_set_current_tabpage(original_tabpage)
      end)

      it("keeps the container list and subscription when opening logs in another tab and returning", function()
        local handle = assert(open_view("container"))
        local subscription = assert(handle.subscription)
        local lines = vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false)
        vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 3 })

        lifecycle.dispatch_for_test(handle, "logs")

        assert.is_true(vim.api.nvim_get_current_tabpage() ~= original_tabpage)
        assert.are.equal(handle, lifecycle.get("container"))
        assert.is_true(vim.api.nvim_win_is_valid(handle.window.winid))
        assert.is_true(subscription.is_alive())
        vim.cmd("tabclose!")
        assert.are.equal(handle.window.winid, vim.api.nvim_get_current_win())
        assert.are.same(lines, vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false))
        assert.are.same({ 1, 3 }, vim.api.nvim_win_get_cursor(handle.window.winid))
      end)

      it("releases the list and subscription when its tab is closed from another tab", function()
        vim.cmd("tabnew")
        local source_tabpage = vim.api.nvim_get_current_tabpage()
        local handle = assert(open_view("container"))
        local subscription = assert(handle.subscription)
        vim.api.nvim_set_current_tabpage(original_tabpage)
        assert.are.equal(handle, lifecycle.get("container"))
        assert.is_true(subscription.is_alive())

        vim.cmd("tabclose! " .. vim.api.nvim_tabpage_get_number(source_tabpage))

        assert(vim.wait(1000, function()
          return lifecycle.get("container") == nil
        end))
        assert.is_false(vim.api.nvim_win_is_valid(handle.window.winid))
        assert.is_false(subscription.is_alive())
      end)

      it("closes only the lists and help in the current tab when entering a plain window", function()
        local containers = assert(open_view("container"))
        lifecycle.dispatch_for_test(containers, "help")
        local original_help = vim.api.nvim_get_current_win()
        vim.cmd("tabnew")
        local images = assert(open_view("image"))
        lifecycle.dispatch_for_test(images, "help")
        local current_help = vim.api.nvim_get_current_win()

        enter_plain_window()

        assert.are.equal(containers, lifecycle.get("container"))
        assert.is_true(vim.api.nvim_win_is_valid(containers.window.winid))
        assert.is_true(assert(containers.subscription).is_alive())
        assert.is_true(vim.api.nvim_win_is_valid(original_help))
        assert.is_nil(lifecycle.get("image"))
        assert.is_false(vim.api.nvim_win_is_valid(images.window.winid))
        assert.is_false(vim.api.nvim_win_is_valid(current_help))
      end)
    end)

    it("closes the list when moving to a window outside it", function()
      local handle = assert(open_view("container"))

      enter_plain_window()

      assert.is_nil(lifecycle.get("container"), "the view should be released")
      assert.is_false(vim.api.nvim_win_is_valid(handle.window.winid))
    end)

    it("stops the event subscription too when moving outside the list", function()
      -- If only the window is closed and the subscription remains, the docker events child
      -- process leaks.
      local handle = assert(open_view("container"))
      local subscription = assert(handle.subscription, "a subscription should be established")

      enter_plain_window()

      assert.is_false(subscription.is_alive())
    end)

    it("keeps the list open when help is opened in front of it", function()
      -- BR-018: closing the upper layer preserves the lower layer's contents and cursor position.
      local handle = assert(open_view("container"))

      vim.api.nvim_set_current_win(handle.window.winid)
      lifecycle.dispatch_for_test(handle, "help")

      assert.is_truthy(lifecycle.get("container"), "the list should remain")
      assert.is_true(vim.api.nvim_win_is_valid(handle.window.winid))
    end)

    it("keeps the original list open when drilling down into a list of another kind", function()
      local handle = assert(open_view("container"))

      vim.api.nvim_set_current_win(handle.window.winid)
      lifecycle.dispatch_for_test(handle, "drilldown")
      vim.wait(500, function()
        return lifecycle.get("image") ~= nil
      end)

      assert.is_truthy(lifecycle.get("image"), "the drilldown target should open")
      assert.is_truthy(lifecycle.get("container"), "the original list should remain")
    end)

    it("keeps the list open when moving to a float that does not belong to the plugin", function()
      -- In environments that implement vim.ui.input as a float, merely showing a confirmation
      -- prompt must not make the list disappear.
      local handle = assert(open_view("container"))

      local bufnr = vim.api.nvim_create_buf(false, true)
      local prompt = vim.api.nvim_open_win(bufnr, true, {
        relative = "editor",
        width = 20,
        height = 1,
        row = 1,
        col = 1,
        style = "minimal",
      })

      assert.is_truthy(lifecycle.get("container"), "the list should remain")
      assert.is_true(vim.api.nvim_win_is_valid(handle.window.winid))
      vim.api.nvim_win_close(prompt, true)
    end)

    it("closes both when moving outside the list while help is still open", function()
      local handle = assert(open_view("container"))
      vim.api.nvim_set_current_win(handle.window.winid)
      lifecycle.dispatch_for_test(handle, "help")
      local help_winid = vim.api.nvim_get_current_win()

      enter_plain_window()

      assert.is_false(vim.api.nvim_win_is_valid(help_winid), "the help view should close")
      assert.is_false(vim.api.nvim_win_is_valid(handle.window.winid), "the list should close too")
    end)

    it("closes every list and stops their subscriptions even when several are open", function()
      -- Closing only one and missing the rest leaks the docker events child processes.
      local containers = assert(open_view("container"))
      local images = assert(open_view("image"))
      local subscriptions = {
        assert(containers.subscription, "a subscription should be established for container"),
        assert(images.subscription, "a subscription should be established for image"),
      }

      enter_plain_window()

      assert.are.same({ false, false }, {
        subscriptions[1].is_alive(),
        subscriptions[2].is_alive(),
      })
      assert.is_false(vim.api.nvim_win_is_valid(containers.window.winid))
      assert.is_false(vim.api.nvim_win_is_valid(images.window.winid))
    end)

    it("leaves no watcher behind when the last list is closed while focus is on a float", function()
      -- Leaving the cleanup to the focus move caused by closing would keep only the watcher
      -- resident when the destination is one of the plugin's floats.
      local handle = assert(open_view("container"))
      vim.api.nvim_set_current_win(handle.window.winid)
      lifecycle.dispatch_for_test(handle, "help")

      lifecycle.close("container")

      assert.is_nil(lifecycle.get("container"))
      assert.are.same({}, vim.api.nvim_get_autocmds({ group = "DockerNvimViewFocus" }))
    end)

    it("keeps watching the remaining lists after closing one of them with q", function()
      local containers = assert(open_view("container"))
      local images = assert(open_view("image"))

      vim.api.nvim_set_current_win(containers.window.winid)
      lifecycle.dispatch_for_test(containers, "close")
      enter_plain_window()

      assert.is_nil(lifecycle.get("image"), "the remaining list should also close once focus moves outside")
      assert.is_false(vim.api.nvim_win_is_valid(images.window.winid))
    end)

    it("can reopen the list even after opening a file inside a container", function()
      -- Replacing the buffer of the list float destroys the bufhidden=wipe list buffer while
      -- only the window remains, after which open is caught by the "move to the existing view"
      -- path and the list is never rendered again.
      local file_edit = require("docker.handlers.file_edit")
      local handle = assert(open_view("container"))
      local original_input = vim.ui.input
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        on_confirm("/etc/hosts")
      end
      -- Intercept only `cp`, and let the list fetch go through the default fake docker.
      cli._set_executor(function(cmd, opts, on_exit)
        if cmd[2] == "cp" then
          vim.fn.writefile({ "127.0.0.1 localhost" }, cmd[4])
          on_exit({ code = 0, stdout = "", stderr = "" })
          return
        end
        fake_docker(cmd, opts, on_exit)
      end)

      vim.api.nvim_set_current_win(handle.window.winid)
      lifecycle.dispatch_for_test(handle, "edit_file")
      assert(
        vim.wait(3000, function()
          return vim.bo.buftype == "acwrite"
        end),
        "the edit buffer never opened"
      )
      vim.ui.input = original_input
      local edit_bufnr = vim.api.nvim_get_current_buf()

      -- The list is closed, and reopening it renders the contents.
      assert.is_nil(lifecycle.get("container"), "the list should close")
      local reopened = assert(open_view("container"))
      local lines = vim.api.nvim_buf_get_lines(reopened.window.bufnr, 0, -1, false)
      assert.is_truthy(lines[1]:find("web", 1, true), lines[1])

      file_edit._reset()
      vim.api.nvim_buf_delete(edit_bufnr, { force = true })
    end)

    it("leaves no window-move watcher behind after the views are closed", function()
      -- If it stayed resident, it would run on every window move even while no list is open.
      open_view("container")

      lifecycle.close_all()

      local watchers = vim.api.nvim_get_autocmds({ group = "DockerNvimViewFocus" })
      assert.are.same({}, watchers)
    end)

    it("still closes on focus loss when opened again after being closed", function()
      open_view("container")
      lifecycle.close_all()

      local handle = assert(open_view("container"))
      enter_plain_window()

      assert.is_nil(lifecycle.get("container"))
      assert.is_false(vim.api.nvim_win_is_valid(handle.window.winid))
    end)
  end)

  describe("dispatching key presses", function()
    ---@param handle table
    ---@param key string
    local function press(handle, key)
      vim.api.nvim_set_current_win(handle.window.winid)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
    end

    it("closes the list on q", function()
      local handle = assert(open_view("container"))

      press(handle, "q")

      assert.is_nil(lifecycle.get("container"))
    end)

    it("opens help in front on ?", function()
      local handle = assert(open_view("container"))

      press(handle, "?")

      local current = vim.api.nvim_get_current_win()
      assert.is_true(current ~= handle.window.winid, "focus should move to the help window")
      local joined = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      assert.is_truthy(joined:find("start", 1, true), joined)
    end)

    it("calls docker again on R to re-fetch the list", function()
      -- Looking only at the line count would not reveal that R did nothing at all.
      local handle = assert(open_view("container"))
      local calls = {}
      cli._set_executor(function(cmd, _, on_exit)
        table.insert(calls, cmd)
        on_exit({ code = 0, stdout = "", stderr = "" })
      end)

      press(handle, "R")

      assert.are.equal(1, #calls, "the list fetch should be issued exactly once")
      assert.are.equal("ps", calls[1][2])
    end)
  end)

  describe("racing with the asynchronous connection check", function()
    it("does not open a second float when opened again while waiting for the answer", function()
      -- Hammering `:Docker containers` would open several floats before the connection check
      -- answers. The orphaned floats can no longer be closed with q or close().
      local pending_replies = {}
      cli._set_executor(function(cmd, _, on_exit)
        -- Hold back the connection-check answer and issue the second and third open meanwhile
        table.insert(pending_replies, function()
          if cmd[2] == "version" then
            on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
          else
            on_exit({ code = 0, stdout = "", stderr = "" })
          end
        end)
      end)

      local before = #vim.api.nvim_list_wins()
      lifecycle.open("container")
      lifecycle.open("container")
      lifecycle.open("container")
      for _, reply in ipairs(pending_replies) do
        reply()
      end
      vim.wait(200)

      local opened = #vim.api.nvim_list_wins() - before
      assert.is_true(opened <= 1, ("at most 1 window should be opened (actually %d)"):format(opened))
    end)

    it("can still be opened again after the connection failed", function()
      cli._set_executor(function(_, _, on_exit)
        on_exit({ code = 1, stdout = "", stderr = "Cannot connect to the Docker daemon" })
      end)
      assert.is_nil(open_view("container"))

      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "version" then
          on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
        else
          on_exit({ code = 0, stdout = "", stderr = "" })
        end
      end)

      assert.is_truthy(open_view("container"), "opening should not become impossible after a failure")
    end)
  end)

  describe("wiring of the busy marker", function()
    it("shows the busy marker in the list when an operation starts", function()
      -- Marking the ledger alone does not change the screen; it has to be wired through to a redraw.
      local handle = assert(open_view("container"))
      assert.is_nil(vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, 1, false)[1]:find("(busy)", 1, true))

      operations.begin("abc123", "stop")

      assert.is_truthy(
        vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, 1, false)[1]:find("(busy)", 1, true),
        vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, 1, false)[1]
      )
    end)

    it("removes the busy marker when the operation finishes", function()
      local handle = assert(open_view("container"))
      operations.begin("abc123", "stop")

      operations.finish("abc123", "stop")

      -- Compare the whole row, not just the absence of the marker: an implementation that
      -- never redraws would also satisfy "the marker is gone" if the marker never appeared.
      local line = vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, 1, false)[1]
      assert.are.equal("web   " .. string.rep(" ", 18) .. "alpine  Up 5 days", line)
      assert.is_nil(line:find("(busy)", 1, true))
    end)
  end)

  describe("redraw and the cursor", function()
    it("does not send the cursor line back to the top when the list is re-fetched", function()
      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "version" then
          on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
        else
          local rows = {}
          for i = 1, 5 do
            table.insert(
              rows,
              ('{"id":"id%d","name":"c%d","image":"alpine","state":"running","status":"Up",'):format(i, i)
                .. '"ports":"","command":"x","created_at":"now","compose_project":"","compose_service":"","compose_oneoff":""}'
            )
          end
          on_exit({ code = 0, stdout = table.concat(rows, "\n") .. "\n", stderr = "" })
        end
      end)
      local handle = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 4, 0 })

      lifecycle.refresh_view("container")

      assert.are.equal(4, vim.api.nvim_win_get_cursor(handle.window.winid)[1])
    end)
  end)

  describe("scope of the keymaps", function()
    it("does not map the plugin keys globally", function()
      -- BR-014: the plugin's keys do not take effect in buffers other than the list views.
      -- `nvim_buf_get_keymap` only looks at buffer-local maps, so it cannot detect a globally
      -- set map alongside them. Look directly at the global map list for the list view's keys.
      -- (A previous test may have already opened a view, so judge by presence rather than by diff.)
      assert(open_view("container"))

      local global = {}
      for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
        global[m.lhs] = true
      end

      local leaked = {}
      for _, key in ipairs({ "u", "s", "r", "l", "h", "t", "a", "e", "E", "q", "R", "?" }) do
        if global[key] then
          table.insert(leaked, key)
        end
      end
      assert.are.same({}, leaked, "keys leaked to the global scope: " .. vim.inspect(leaked))
    end)

    it("removes that buffer's keys when the view is closed", function()
      local handle = assert(open_view("container"))
      local bufnr = handle.window.bufnr

      lifecycle.close("container")

      assert.is_false(vim.api.nvim_buf_is_valid(bufnr), "the buffer itself should be wiped")
    end)
  end)

  describe("switching views", function()
    it("switches to the chosen kind and closes the original view", function()
      local handle = assert(open_view("container"))
      local original_select = vim.ui.select
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.select = function(items, _, on_choice)
        -- pick images
        for _, item in ipairs(items) do
          if item == "images" then
            on_choice(item)
            return
          end
        end
        on_choice(nil)
      end

      lifecycle.dispatch_for_test(handle, "switch_view")
      vim.wait(1000, function()
        return lifecycle.get("image") ~= nil
      end)
      vim.ui.select = original_select

      assert.is_truthy(lifecycle.get("image"), "the switch target should open")
      assert.is_nil(lifecycle.get("container"), "the original view should close")
    end)

    it("keeps the current view when the selection is cancelled", function()
      local handle = assert(open_view("container"))
      local original_select = vim.ui.select
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.select = function(_, _, on_choice)
        on_choice(nil)
      end

      lifecycle.dispatch_for_test(handle, "switch_view")
      vim.wait(200)
      vim.ui.select = original_select

      assert.is_truthy(lifecycle.get("container"), "the current view should remain")
    end)

    it("does not close the current view when the switch target could not be opened", function()
      -- For example switching to services from outside a compose project.
      local handle = assert(open_view("container"))
      local original_select = vim.ui.select
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.select = function(_, _, on_choice)
        on_choice("services")
      end
      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "version" then
          on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
        else
          on_exit({ code = 1, stdout = "", stderr = "no configuration file provided: not found" })
        end
      end)

      lifecycle.dispatch_for_test(handle, "switch_view")
      vim.wait(500)
      vim.ui.select = original_select

      assert.is_nil(lifecycle.get("service"))
      assert.is_truthy(lifecycle.get("container"), "the current view should remain when the switch fails")
    end)
  end)

  describe("drilldown", function()
    ---@param cmd_handler fun(cmd: string[]): string
    local function stub_lists(cmd_handler)
      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "version" then
          on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
          return
        end
        on_exit({ code = 0, stdout = cmd_handler(cmd), stderr = "" })
      end)
    end

    local function container_json(over)
      return vim.json.encode(vim.tbl_extend("force", {
        id = "c1",
        name = "web",
        image = "alpine",
        state = "running",
        status = "Up",
        ports = "",
        command = "x",
        created_at = "now",
        compose_project = "",
        compose_service = "",
        compose_oneoff = "",
      }, over or {}))
    end

    local function image_json(over)
      return vim.json.encode(vim.tbl_extend("force", {
        id = "i1",
        repository = "alpine",
        tag = "latest",
        created_since = "1d",
        size = "5MB",
      }, over or {}))
    end

    it("moves from a container to its image with the cursor on the target line", function()
      stub_lists(function(cmd)
        if cmd[2] == "image" then
          return image_json({ id = "i0", repository = "other", tag = "1" })
            .. "\n"
            .. image_json({ id = "i1", repository = "alpine", tag = "latest" })
        end
        return container_json({ image = "alpine" })
      end)
      local handle = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 0 })

      lifecycle.dispatch_for_test(handle, "drilldown")
      assert(vim.wait(3000, function()
        return lifecycle.get("image") ~= nil
      end))

      local images = assert(lifecycle.get("image"))
      -- The .Image of `docker ps` can be the tag-less form ("alpine").
      assert.are.equal(2, vim.api.nvim_win_get_cursor(images.window.winid)[1], "cursor should land on the alpine row")
    end)

    it("moves from an image to the container that uses it", function()
      stub_lists(function(cmd)
        if cmd[2] == "image" then
          return image_json({ repository = "alpine", tag = "3.20" })
        end
        return container_json({ id = "c0", name = "other", image = "nginx" })
          .. "\n"
          .. container_json({ id = "c1", name = "target", image = "alpine:3.20" })
      end)
      local handle = assert(open_view("image"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 0 })

      lifecycle.dispatch_for_test(handle, "drilldown")
      assert(vim.wait(3000, function()
        return lifecycle.get("container") ~= nil
      end))

      local containers = assert(lifecycle.get("container"))
      assert.are.equal(2, vim.api.nvim_win_get_cursor(containers.window.winid)[1])
    end)

    it("warns and opens nothing when there is nowhere to drill down to", function()
      stub_lists(function()
        return container_json({ image = "" })
      end)
      local handle = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 0 })

      lifecycle.dispatch_for_test(handle, "drilldown")
      vim.wait(300)

      assert.is_nil(lifecycle.get("image"))
      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
    end)
  end)

  describe("bulk delete", function()
    ---@param count integer
    local function stub_containers(count)
      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "version" then
          on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
          return
        end
        if cmd[2] == "rm" then
          on_exit({ code = 0, stdout = "", stderr = "" })
          return
        end
        local rows = {}
        for i = 1, count do
          table.insert(
            rows,
            vim.json.encode({
              id = "id" .. i,
              name = "c" .. i,
              image = "alpine",
              state = "exited",
              status = "Exited",
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
    end

    it("maps the delete key in Visual mode as well", function()
      -- With Normal mode alone, selecting a range and pressing the key never reaches the plugin.
      stub_containers(3)
      local handle = assert(open_view("container"))

      local visual = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(handle.window.bufnr, "x")) do
        visual[m.lhs] = true
      end

      assert.is_true(visual["D"], "D should be mapped in Visual mode")
    end)

    it("shows the number of selected rows in the confirmation prompt", function()
      stub_containers(3)
      local handle = assert(open_view("container"))
      local prompts = {}
      local original_input = vim.ui.input
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(opts, on_confirm)
        table.insert(prompts, opts.prompt)
        on_confirm("n")
      end

      vim.api.nvim_set_current_win(handle.window.winid)
      vim.cmd("normal! ggVjj")
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("D", true, false, true), "x", false)
      vim.wait(300)
      vim.ui.input = original_input

      assert.are.equal(1, #prompts, "the confirmation should be shown exactly once")
      assert.is_truthy(prompts[1]:find("3", 1, true), prompts[1])
    end)

    it("deletes as many rows as were selected when the confirmation is answered with y", function()
      stub_containers(3)
      local handle = assert(open_view("container"))
      local removed = {}
      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "rm" then
          table.insert(removed, cmd[3])
          on_exit({ code = 0, stdout = "", stderr = "" })
          return
        end
        on_exit({ code = 0, stdout = "", stderr = "" })
      end)
      local original_input = vim.ui.input
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        on_confirm("y")
      end

      vim.api.nvim_set_current_win(handle.window.winid)
      vim.cmd("normal! ggVj")
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("D", true, false, true), "x", false)
      vim.wait(500)
      vim.ui.input = original_input

      table.sort(removed)
      assert.are.same({ "id1", "id2" }, removed)
    end)

    it("deletes nothing when the confirmation is answered with n", function()
      stub_containers(3)
      local handle = assert(open_view("container"))
      local removed = {}
      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "rm" then
          table.insert(removed, cmd[3])
        end
        on_exit({ code = 0, stdout = "", stderr = "" })
      end)
      local original_input = vim.ui.input
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        on_confirm("n")
      end

      vim.api.nvim_set_current_win(handle.window.winid)
      vim.cmd("normal! ggVj")
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("D", true, false, true), "x", false)
      vim.wait(300)
      vim.ui.input = original_input

      assert.are.same({}, removed)
    end)

    it("deletes the rest even when some fail and reports the failures together", function()
      stub_containers(3)
      local handle = assert(open_view("container"))
      local removed = {}
      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "rm" then
          table.insert(removed, cmd[3])
          if cmd[3] == "id1" then
            on_exit({ code = 1, stdout = "", stderr = "container is running" })
          else
            on_exit({ code = 0, stdout = "", stderr = "" })
          end
          return
        end
        on_exit({ code = 0, stdout = "", stderr = "" })
      end)
      local original_input = vim.ui.input
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        on_confirm("y")
      end

      vim.api.nvim_set_current_win(handle.window.winid)
      vim.cmd("normal! ggVj")
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("D", true, false, true), "x", false)
      vim.wait(500)
      vim.ui.input = original_input

      assert.are.equal(2, #removed, "the others should still run even when one fails")
      local last = notified[#notified]
      assert.are.equal(vim.log.levels.ERROR, last.level)
      assert.is_truthy(last.msg:find("id1", 1, true) or last.msg:find("c1", 1, true), last.msg)
    end)
  end)

  describe("container list grouping", function()
    local events = require("docker.adapters.docker.events")
    local jobs = require("docker.handlers.jobs")

    ---@param overrides table
    ---@return string
    local function container_json(overrides)
      return vim.json.encode(vim.tbl_extend("force", {
        id = "c1",
        name = "web",
        image = "alpine",
        state = "running",
        status = "Up",
        ports = "",
        command = "x",
        created_at = "now",
        compose_project = "",
        compose_service = "",
        compose_oneoff = "False",
        compose_working_dir = "",
      }, overrides))
    end

    ---@param rows string[]
    ---@param runs table[]|nil
    local function stub_containers(rows, runs)
      cli._set_executor(function(cmd, opts, on_exit)
        if runs then
          table.insert(runs, { cmd = cmd, opts = opts })
        end
        if cmd[2] == "version" then
          on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
          return
        end
        if cmd[2] == "ps" then
          on_exit({ code = 0, stdout = table.concat(rows, "\n") .. "\n", stderr = "" })
          return
        end
        on_exit({ code = 0, stdout = "", stderr = "" })
      end)
    end

    before_each(function()
      jobs._reset()
      events._set_starter(function()
        return 999
      end)
      events._set_waiter(function() end)
    end)

    after_each(function()
      events._set_starter(nil)
      events._set_waiter(nil)
      jobs._reset()
    end)

    ---@param handle docker.ViewHandle
    ---@return string[]
    local function lines(handle)
      return vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false)
    end

    it("folds and expands the project on <CR>", function()
      stub_containers({
        container_json({ id = "c1", name = "shop-web-1", compose_project = "shop", compose_service = "web" }),
        container_json({ id = "c2", name = "shop-db-1", compose_project = "shop", compose_service = "db" }),
        container_json({ id = "c3", name = "plain" }),
      })
      local handle = assert(open_view("container"))

      assert.are.equal(4, #lines(handle), "the project header, its 2 containers and the plain container")
      assert.is_truthy(lines(handle)[1]:find("▾ shop", 1, true), lines(handle)[1])

      vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 0 })
      lifecycle.dispatch_for_test(handle, "inspect")

      assert.are.equal(2, #lines(handle), "the shop containers should be folded")
      assert.is_truthy(lines(handle)[1]:find("▸ shop", 1, true), lines(handle)[1])

      lifecycle.dispatch_for_test(handle, "inspect")

      assert.are.equal(4, #lines(handle), "the shop containers should be expanded again")
      assert.is_truthy(lines(handle)[1]:find("▾ shop", 1, true), lines(handle)[1])
    end)

    it("expands the project with l and collapses it with h", function()
      stub_containers({
        container_json({ id = "c1", name = "shop-web-1", compose_project = "shop", compose_service = "web" }),
        container_json({ id = "c2", name = "shop-db-1", compose_project = "shop", compose_service = "db" }),
      })
      local handle = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 0 })

      lifecycle.dispatch_for_test(handle, "collapse_group")
      assert.are.equal(1, #lines(handle))
      assert.is_truthy(lines(handle)[1]:find("▸ shop", 1, true), lines(handle)[1])

      lifecycle.dispatch_for_test(handle, "expand_group")
      assert.are.equal(3, #lines(handle))
      assert.is_truthy(lines(handle)[1]:find("▾ shop", 1, true), lines(handle)[1])
    end)

    it("collapses the parent project from a child row and moves the cursor to the header", function()
      stub_containers({
        container_json({ id = "c1", name = "shop-web-1", compose_project = "shop", compose_service = "web" }),
        container_json({ id = "c2", name = "shop-db-1", compose_project = "shop", compose_service = "db" }),
      })
      local handle = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 2, 0 })

      lifecycle.dispatch_for_test(handle, "collapse_group")

      assert.are.equal(1, #lines(handle))
      assert.are.equal(1, vim.api.nvim_win_get_cursor(handle.window.winid)[1], "the cursor should move to the header")
    end)

    it("does nothing when l is pressed on an already expanded project", function()
      stub_containers({
        container_json({ id = "c1", name = "shop-web-1", compose_project = "shop", compose_service = "web" }),
      })
      local handle = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 0 })

      lifecycle.dispatch_for_test(handle, "expand_group")

      assert.are.equal(2, #lines(handle))
    end)

    it("warns when the group keys are pressed on a row that has no project", function()
      stub_containers({ container_json({ id = "c1", name = "plain" }) })
      local handle = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 0 })

      lifecycle.dispatch_for_test(handle, "expand_group")

      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
      assert.is_truthy(notified[#notified].msg:find("project row", 1, true), notified[#notified].msg)
    end)

    it("still inspects the container on <CR> when the cursor is on a container row", function()
      local inspected = {}
      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "version" then
          on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
          return
        end
        if cmd[2] == "inspect" then
          table.insert(inspected, cmd[3])
          on_exit({ code = 0, stdout = "[]", stderr = "" })
          return
        end
        on_exit({
          code = 0,
          stdout = container_json({ id = "c1", name = "shop-web-1", compose_project = "shop", compose_service = "web" })
            .. "\n",
          stderr = "",
        })
      end)
      local handle = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 2, 0 })

      lifecycle.dispatch_for_test(handle, "inspect")

      assert(vim.wait(3000, function()
        return #inspected > 0
      end))
      assert.are.same({ "c1" }, inspected)
    end)

    it("starts the whole project when start is pressed on the project row", function()
      local runs = {}
      stub_containers({
        container_json({
          id = "c1",
          name = "shop-web-1",
          compose_project = "shop",
          compose_service = "web",
        }),
      }, runs)
      local handle = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 0 })

      lifecycle.dispatch_for_test(handle, "start")

      assert.are.same({ "docker", "start", "c1" }, runs[#runs].cmd)
    end)

    it("stops and restarts every container of a label-only project", function()
      -- `gather-clone` is created by the Supabase CLI: its containers carry the compose project
      -- label but no compose service label, and `docker compose -p gather-clone stop` does nothing.
      -- The project row must still stop the containers it groups.
      local runs = {}
      stub_containers({
        container_json({ id = "c1", name = "supabase_studio_gather-clone", compose_project = "gather-clone" }),
        container_json({ id = "c2", name = "supabase_db_gather-clone", compose_project = "gather-clone" }),
      }, runs)
      local handle = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 0 })

      lifecycle.dispatch_for_test(handle, "stop")
      assert.are.same({ "docker", "stop", "c1", "c2" }, runs[#runs].cmd)

      lifecycle.dispatch_for_test(handle, "restart")
      assert.are.same({ "docker", "restart", "c1", "c2" }, runs[#runs].cmd)
    end)

    it("kills the running containers of a label-only project", function()
      local runs = {}
      stub_containers({
        container_json({
          id = "c1",
          name = "supabase_studio_gather-clone",
          compose_project = "gather-clone",
          state = "running",
        }),
        container_json({
          id = "c2",
          name = "supabase_db_gather-clone",
          compose_project = "gather-clone",
          state = "exited",
        }),
      }, runs)
      local handle = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 0 })

      lifecycle.dispatch_for_test(handle, "kill")

      -- Only the running container is passed; `docker kill` would fail on the exited one.
      assert.are.same({ "docker", "kill", "c1" }, runs[#runs].cmd)
    end)

    it("removes the whole project when delete is pressed on the project row", function()
      local runs = {}
      stub_containers({
        container_json({ id = "c1", name = "supabase_studio_gather-clone", compose_project = "gather-clone" }),
        container_json({ id = "c2", name = "supabase_db_gather-clone", compose_project = "gather-clone" }),
      }, runs)
      local handle = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 0 })
      local original_input = vim.ui.input
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        on_confirm("y")
      end

      lifecycle.dispatch_for_test(handle, "delete")
      vim.ui.input = original_input

      assert.are.same({ "docker", "rm", "c1", "c2" }, runs[#runs].cmd)
    end)

    it("warns for a container-only operation on the project row", function()
      stub_containers({
        container_json({ id = "c1", name = "shop-web-1", compose_project = "shop", compose_service = "web" }),
      })
      local handle = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 0 })

      lifecycle.dispatch_for_test(handle, "logs")

      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
      assert.is_truthy(notified[#notified].msg:find("project row", 1, true), notified[#notified].msg)
    end)

    it("shows a matching container inside a folded project while a filter is active", function()
      stub_containers({
        container_json({ id = "c1", name = "shop-web-1", compose_project = "shop", compose_service = "web" }),
        container_json({ id = "c2", name = "shop-db-1", compose_project = "shop", compose_service = "db" }),
      })
      local handle = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 0 })
      lifecycle.dispatch_for_test(handle, "inspect")
      assert.are.equal(1, #lines(handle))

      local original_input = vim.ui.input
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        on_confirm("web")
      end
      lifecycle.dispatch_for_test(handle, "filter")
      vim.ui.input = original_input

      assert.are.equal(2, #lines(handle), "the matching container should be visible even inside a folded group")
      assert.is_truthy(lines(handle)[2]:find("shop-web-1", 1, true), lines(handle)[2])

      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        on_confirm("")
      end
      lifecycle.dispatch_for_test(handle, "filter")
      vim.ui.input = original_input

      assert.are.equal(1, #lines(handle), "the group should be folded again once the filter is cleared")
    end)

    it("stops every container of the project even when a filter hides some of them", function()
      local runs = {}
      stub_containers({
        container_json({ id = "c1", name = "shop-web-1", compose_project = "shop", compose_service = "web" }),
        container_json({ id = "c2", name = "shop-db-1", compose_project = "shop", compose_service = "db" }),
      }, runs)
      local handle = assert(open_view("container"))
      local original_input = vim.ui.input
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        on_confirm("web")
      end
      lifecycle.dispatch_for_test(handle, "filter")
      vim.ui.input = original_input
      assert.are.equal(2, #lines(handle), "only the matching container should be visible")

      vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 0 })
      lifecycle.dispatch_for_test(handle, "stop")

      assert.are.same({ "docker", "stop", "c1", "c2" }, runs[#runs].cmd)
    end)

    it("expands a folded project when drilling down into one of its containers", function()
      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "version" then
          on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
          return
        end
        if cmd[2] == "ps" then
          on_exit({
            code = 0,
            stdout = container_json({
              id = "c1",
              name = "shop-web-1",
              image = "alpine:latest",
              compose_project = "shop",
              compose_service = "web",
            }) .. "\n",
            stderr = "",
          })
          return
        end
        if cmd[2] == "image" then
          on_exit({
            code = 0,
            stdout = vim.json.encode({
              id = "i1",
              repository = "alpine",
              tag = "latest",
              size = "5MB",
              created_since = "now",
            }) .. "\n",
            stderr = "",
          })
          return
        end
        on_exit({ code = 0, stdout = "", stderr = "" })
      end)
      local containers = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(containers.window.winid, { 1, 0 })
      lifecycle.dispatch_for_test(containers, "inspect")
      assert.are.equal(1, #lines(containers), "the project should be folded first")

      local images = assert(open_view("image"))
      vim.api.nvim_win_set_cursor(images.window.winid, { 1, 0 })
      lifecycle.dispatch_for_test(images, "drilldown")

      assert(
        vim.wait(3000, function()
          return #lines(containers) == 2
        end),
        "the folded project should be expanded to reveal the target"
      )
      assert.are.equal(2, vim.api.nvim_win_get_cursor(containers.window.winid)[1])
    end)

    it("shows the busy marker on the project header while a project operation runs", function()
      stub_containers({
        container_json({ id = "c1", name = "shop-web-1", compose_project = "shop", compose_service = "web" }),
      })
      local handle = assert(open_view("container"))

      operations.begin("shop", "project_stop")

      assert.is_truthy(lines(handle)[1]:find("(busy)", 1, true), lines(handle)[1])

      operations.finish("shop", "project_stop")

      assert.is_nil(lines(handle)[1]:find("(busy)", 1, true), lines(handle)[1])
    end)
  end)

  describe("target of the inspect view", function()
    it("inspects the resource on the cursor line", function()
      -- An implementation that always looks at the first line would show the details of a
      -- different container.
      local inspected = {}
      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "version" then
          on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
          return
        end
        if cmd[2] == "inspect" then
          table.insert(inspected, cmd[3])
          on_exit({ code = 0, stdout = "[{}]", stderr = "" })
          return
        end
        local rows = {}
        for i = 1, 3 do
          table.insert(
            rows,
            vim.json.encode({
              id = "id" .. i,
              name = "c" .. i,
              image = "alpine",
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
      local handle = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 2, 0 })

      lifecycle.dispatch_for_test(handle, "inspect")
      assert(vim.wait(3000, function()
        return #inspected > 0
      end))

      assert.are.same({ "id2" }, inspected)
    end)
  end)
end)
