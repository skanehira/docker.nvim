local cli = require("docker.adapters.docker.cli")
local notify = require("docker.notify")

describe("docker.adapters.docker.cli", function()
  local calls

  --- Installs a fake executor that returns the given exit state.
  ---@param out { code: integer, stdout: string|nil, stderr: string|nil }
  local function stub_executor(out)
    cli._set_executor(function(cmd, opts, on_exit)
      table.insert(calls, { cmd = cmd, opts = opts })
      on_exit({ code = out.code, stdout = out.stdout or "", stderr = out.stderr or "" })
    end)
  end

  ---@return docker.Result
  local function run_sync(args, opts)
    local captured
    cli.run(args, function(result)
      captured = result
    end, opts)
    return assert(captured, "on_done was not called")
  end

  before_each(function()
    calls = {}
  end)

  after_each(function()
    cli._set_executor(nil)
    notify.set_debug(false)
  end)

  describe("run", function()
    it("prepends docker to the arguments and passes them to the executor", function()
      stub_executor({ code = 0, stdout = "" })

      run_sync({ "ps", "-a" })

      assert.are.same({ "docker", "ps", "-a" }, calls[1].cmd)
    end)

    it("reports success and puts stdout as-is into data when the exit code is 0", function()
      stub_executor({ code = 0, stdout = "hello\n" })

      assert.are.same({ ok = true, data = "hello\n", error = nil, code = 0 }, run_sync({ "version" }))
    end)

    it("puts the parsed table into data when parse is set to ndjson", function()
      stub_executor({ code = 0, stdout = '{"id":"a"}\n{"id":"b"}\n' })

      assert.are.same(
        { ok = true, data = { { id = "a" }, { id = "b" } }, error = nil, code = 0 },
        run_sync({ "ps" }, { parse = "ndjson" })
      )
    end)

    it("parses a single JSON document into data when parse is set to json", function()
      stub_executor({ code = 0, stdout = '{"name":"bridge"}' })

      assert.are.same(
        { ok = true, data = { name = "bridge" }, error = nil, code = 0 },
        run_sync({ "inspect", "bridge" }, { parse = "json" })
      )
    end)

    it("reports failure and puts stderr as-is into error when the exit code is non-zero", function()
      stub_executor({ code = 1, stderr = "Error response from daemon: conflict\n" })

      assert.are.same(
        { ok = false, data = nil, error = "Error response from daemon: conflict", code = 1 },
        run_sync({ "rm", "web" })
      )
    end)

    it("returns a default message containing the exit code when stderr is empty on failure", function()
      stub_executor({ code = 125, stderr = "" })

      assert.are.same(
        { ok = false, data = nil, error = "docker exited with code 125", code = 125 },
        run_sync({ "start", "web" })
      )
    end)

    it("returns an error when the output cannot be parsed even though the command succeeded", function()
      stub_executor({ code = 0, stdout = "not json" })

      assert.are.same({
        ok = false,
        data = nil,
        error = "failed to parse docker output",
        code = 0,
      }, run_sync({ "inspect", "web" }, { parse = "json" }))
    end)

    it("returns an error when parse is set to json and the output is not an object", function()
      -- `{{json .X}}` prints null for fields that have no value, so this really can happen.
      -- Reject it here so that callers can treat data as a table.
      for _, stdout in ipairs({ "null", "123", '"text"', "true" }) do
        stub_executor({ code = 0, stdout = stdout })

        assert.are.same({
          ok = false,
          data = nil,
          error = "failed to parse docker output",
          code = 0,
        }, run_sync({ "inspect", "web" }, { parse = "json" }), "input: " .. stdout)
      end
    end)

    it("passes cwd through to the executor options when it is specified", function()
      stub_executor({ code = 0, stdout = "" })

      run_sync({ "compose", "ps" }, { cwd = "/tmp/proj" })

      assert.are.equal("/tmp/proj", calls[1].opts.cwd)
    end)

    it("calls the completion callback exactly once", function()
      stub_executor({ code = 0, stdout = "ok" })

      local count = 0
      cli.run({ "ps" }, function()
        count = count + 1
      end)

      assert.are.equal(1, count)
    end)

    it("returns an error when the execution result reports no exit code", function()
      cli._set_executor(function(_, _, on_exit)
        on_exit({ stdout = "", stderr = "" })
      end)

      assert.are.same({
        ok = false,
        data = nil,
        error = "docker did not report an exit code",
        code = nil,
      }, run_sync({ "ps" }))
    end)

    it("returns an error instead of 0 items when no ndjson line can be parsed", function()
      stub_executor({ code = 0, stdout = "broken\nalso broken\n" })

      assert.are.same({
        ok = false,
        data = nil,
        error = "failed to parse all 2 line(s) of docker output",
        code = 0,
      }, run_sync({ "ps" }, { parse = "ndjson" }))
    end)

    it("returns the lines it could parse when only some ndjson lines fail to parse", function()
      stub_executor({ code = 0, stdout = '{"id":"a"}\nbroken\n' })

      assert.are.same(
        { ok = true, data = { { id = "a" } }, error = nil, code = 0 },
        run_sync({ "ps" }, { parse = "ndjson" })
      )
    end)

    it("returns a failure when terminated by a signal even if the exit code is 0", function()
      -- vim.system returns code=0, signal=15 for a process killed by a signal.
      -- Treating it as a success would interpret truncated output as "all items".
      cli._set_executor(function(_, _, on_exit)
        on_exit({ code = 0, signal = 15, stdout = '{"id":"a"}\n', stderr = "" })
      end)

      assert.are.same({
        ok = false,
        data = nil,
        error = "docker was terminated by signal 15",
        code = 0,
      }, run_sync({ "ps" }, { parse = "ndjson" }))
    end)

    it("treats signal 0 of a normal exit as a success", function()
      cli._set_executor(function(_, _, on_exit)
        on_exit({ code = 0, signal = 0, stdout = "ok", stderr = "" })
      end)

      assert.are.same({ ok = true, data = "ok", error = nil, code = 0 }, run_sync({ "ps" }))
    end)

    it("calls the executor exactly once without retrying", function()
      -- Operations with side effects are not retried automatically (section 8.2).
      stub_executor({ code = 1, stderr = "boom" })

      run_sync({ "start", "web" })

      assert.are.equal(1, #calls)
    end)
  end)

  describe("delivery in a fast event context", function()
    it("delivers the result and keeps the debug notification when the executor completes in a fast event", function()
      -- The on_exit of vim.system is called in a fast event context, where vim.notify fails with
      -- E5560. Unless the adapter layer absorbs it, on_done is never called.
      notify.set_debug(true)
      cli._set_executor(function(_, _, on_exit)
        -- Use an external process unrelated to docker so that a real fast event context is created.
        vim.system({ "sh", "-c", "exit 0" }, { text = true }, function()
          assert(vim.in_fast_event(), "this path is expected to be a fast event context")
          on_exit({ code = 0, stdout = "delivered", stderr = "" })
        end)
      end)

      local captured
      cli.run({ "ps" }, function(result)
        captured = result
      end)

      local ok = vim.wait(3000, function()
        return captured ~= nil
      end)

      assert.is_true(ok, "on_done must be called (it must not be swallowed in the fast event)")
      assert.are.same({ ok = true, data = "delivered", error = nil, code = 0 }, captured)
    end)
  end)

  describe("default executor", function()
    local original_system

    --- The default executor returns even a startup failure on the next event loop tick, so we wait
    --- before verifying.
    ---@return docker.Result
    local function run_async(args, opts)
      local captured
      cli.run(args, function(result)
        captured = result
      end, opts)
      local ok = vim.wait(3000, function()
        return captured ~= nil
      end)
      assert(ok, "on_done was not called")
      return captured
    end

    before_each(function()
      cli._set_executor(nil)
      original_system = vim.system
    end)

    after_each(function()
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.system = original_system
    end)

    it("does not deliver the result within the same event loop even when the start fails", function()
      -- Returning only a startup failure synchronously would deliver a failure issued later before
      -- an execution issued earlier, swapping the call order and the delivery order.
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.system = function()
        error("ENOENT: no such file or directory")
      end

      local delivered = false
      cli.run({ "ps" }, function()
        delivered = true
      end)

      assert.is_false(delivered, "on_done must not be called inside cli.run")

      vim.wait(3000, function()
        return delivered
      end)
      assert.is_true(delivered, "it must be delivered on a later event loop tick")
    end)

    it("passes the command and an existing cwd through to vim.system as-is", function()
      local cwd = vim.fn.getcwd()
      local passed
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.system = function(cmd, opts, on_exit)
        passed = { cmd = cmd, opts = opts }
        on_exit({ code = 0, stdout = "out", stderr = "" })
      end

      local result = run_async({ "ps", "-a" }, { cwd = cwd })

      assert.are.same({ "docker", "ps", "-a" }, passed.cmd)
      assert.are.equal(cwd, passed.opts.cwd)
      assert.are.same({ ok = true, data = "out", error = nil, code = 0 }, result)
    end)

    it("converts to a result with exit code 127 when docker cannot run and vim.system throws", function()
      -- vim.system throws instead of returning an exit code when the executable is missing.
      -- Letting the exception propagate would break the docker.Result contract and make G11's
      -- "docker not found" indistinguishable from the other environment errors.
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.system = function()
        error("ENOENT: no such file or directory")
      end

      local result = run_async({ "ps" })

      assert.is_false(result.ok)
      assert.are.equal(127, result.code)
      assert.is_truthy(
        tostring(result.error):find("executable not found", 1, true),
        "the synthesized stderr must contain executable not found: " .. tostring(result.error)
      )
    end)

    it("does not confuse a missing working directory with docker not being found", function()
      -- A missing cwd also arrives through the same path as a vim.system exception. Folding it into
      -- "docker is missing" would misguide the user with "please install docker" (compose passes cwd).
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.system = function()
        error("ENOENT: no such file or directory: cwd")
      end

      local result = run_async({ "compose", "ps" }, { cwd = "/no/such/dir" })

      assert.is_false(result.ok)
      assert.is_truthy(
        tostring(result.error):find("working directory not found", 1, true),
        "the wording must make clear that it is a working directory problem: " .. tostring(result.error)
      )
      assert.is_nil(tostring(result.error):find("executable not found", 1, true))
    end)

    it("returns the not-found message from the connection check when docker cannot run", function()
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.system = function()
        error("ENOENT: no such file or directory")
      end

      local captured
      cli.check_connection(function(result)
        captured = result
      end)
      assert(
        vim.wait(3000, function()
          return captured ~= nil
        end),
        "on_done was not called"
      )

      assert.are.same({
        ok = false,
        data = nil,
        error = "docker command not found. Install docker and make sure it is on PATH.",
        code = 127,
      }, captured)
    end)
  end)

  describe("check_connection", function()
    ---@return docker.Result
    local function check_sync()
      local captured
      cli.check_connection(function(result)
        captured = result
      end)
      return assert(captured, "on_done was not called")
    end

    it("reports success and puts the server version into data when the daemon can be reached", function()
      stub_executor({ code = 0, stdout = "29.4.0\n" })

      assert.are.same({ ok = true, data = "29.4.0", error = nil, code = 0 }, check_sync())
    end)

    it("calls docker with arguments that fetch only the server version", function()
      stub_executor({ code = 0, stdout = "29.4.0\n" })

      check_sync()

      assert.are.same({ "docker", "version", "--format", "{{.Server.Version}}" }, calls[1].cmd)
    end)

    it("does not mistake a key error over SSH for insufficient socket permission", function()
      -- Deciding on `permission denied` alone would misguide the user about the public key error
      -- emitted when the docker context is SSH, telling them to check their docker group membership.
      stub_executor({ code = 1, stderr = "ssh: Permission denied (publickey)." })

      assert.are.same({
        ok = false,
        data = nil,
        error = "ssh: Permission denied (publickey).",
        code = 1,
      }, check_sync())
    end)

    it("classifies a daemon socket permission denial as a permission error with the socket context", function()
      stub_executor({
        code = 1,
        stderr = "Got permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock",
      })

      assert.are.same({
        ok = false,
        data = nil,
        error = "No permission to access the docker socket. Make sure your user belongs to the docker group.",
        code = 1,
      }, check_sync())
    end)

    it("returns a message prompting installation when the docker command is not found", function()
      stub_executor({ code = 127, stderr = "docker: executable not found" })

      assert.are.same({
        ok = false,
        data = nil,
        error = "docker command not found. Install docker and make sure it is on PATH.",
        code = 127,
      }, check_sync())
    end)

    it("returns a message prompting startup when the daemon cannot be reached", function()
      stub_executor({
        code = 1,
        stderr = "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?",
      })

      assert.are.same({
        ok = false,
        data = nil,
        error = "Cannot connect to the docker daemon. Make sure docker is running.",
        code = 1,
      }, check_sync())
    end)

    it("classifies daemon-not-running and insufficient permission separately with docker 29 wording", function()
      -- The wording differs between docker 28 and earlier and docker 29. We pin the strings captured
      -- on a real machine (docker 29.4.0) to detect a regression where the check silently stops
      -- working on newer docker.
      local cases = {
        {
          stderr = "failed to connect to the docker API at unix:///var/run/docker.sock; check if the path is correct and if the daemon is running: dial unix /var/run/docker.sock: connect: no such file or directory",
          expected = "Cannot connect to the docker daemon. Make sure docker is running.",
        },
        {
          -- Even in setups where the socket path is not docker.sock (colima / rancher / a custom
          -- socket), the mention of "docker API" is enough to classify it as a permission error.
          stderr = "permission denied while trying to connect to the docker API at unix:///var/run/engine.sock",
          expected = "No permission to access the docker socket. Make sure your user belongs to the docker group.",
        },
      }

      local actual = {}
      for _, case in ipairs(cases) do
        stub_executor({ code = 1, stderr = case.stderr })
        table.insert(actual, check_sync().error)
      end

      assert.are.same({ cases[1].expected, cases[2].expected }, actual)
    end)

    it("returns a message about permission when there is no permission on the socket", function()
      stub_executor({
        code = 1,
        stderr = "dial unix /var/run/docker.sock: connect: permission denied",
      })

      assert.are.same({
        ok = false,
        data = nil,
        error = "No permission to access the docker socket. Make sure your user belongs to the docker group.",
        code = 1,
      }, check_sync())
    end)

    it("produces messages that distinguish the three environment errors from each other", function()
      local messages = {}
      for _, stderr in ipairs({
        "docker: executable not found",
        "Cannot connect to the Docker daemon at unix:///var/run/docker.sock.",
        "dial unix /var/run/docker.sock: connect: permission denied",
      }) do
        stub_executor({ code = 1, stderr = stderr })
        local result = check_sync()
        table.insert(messages, result.error)
      end

      assert.are.same({
        "docker command not found. Install docker and make sure it is on PATH.",
        "Cannot connect to the docker daemon. Make sure docker is running.",
        "No permission to access the docker socket. Make sure your user belongs to the docker group.",
      }, messages)
    end)

    it("returns docker's stderr as-is for a failure that matches none of them", function()
      stub_executor({ code = 1, stderr = "something else went wrong" })

      assert.are.same({
        ok = false,
        data = nil,
        error = "something else went wrong",
        code = 1,
      }, check_sync())
    end)
  end)

  describe("debug log", function()
    local original_notify
    local notified

    before_each(function()
      notified = {}
      original_notify = vim.notify
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.notify = function(msg, level, opts)
        table.insert(notified, { msg = msg, level = level, opts = opts })
      end
    end)

    after_each(function()
      vim.notify = original_notify
    end)

    it("does not notify the executed command by default", function()
      stub_executor({ code = 0, stdout = "" })

      run_sync({ "ps", "-a" })

      assert.are.same({}, notified)
    end)

    it("notifies the executed command and its exit code when debug is enabled", function()
      notify.set_debug(true)
      stub_executor({ code = 0, stdout = "" })

      run_sync({ "ps", "-a" })

      assert.are.same({
        { msg = "docker ps -a (exit 0)", level = vim.log.levels.DEBUG, opts = { title = "docker.nvim" } },
      }, notified)
    end)

    it("also notifies the number of lines that failed to parse when debug is enabled", function()
      notify.set_debug(true)
      stub_executor({ code = 0, stdout = '{"id":"a"}\nbroken\n' })

      run_sync({ "ps" }, { parse = "ndjson" })

      assert.are.same({
        { msg = "docker ps (exit 0)", level = vim.log.levels.DEBUG, opts = { title = "docker.nvim" } },
        { msg = "skipped 1 unparsable line(s)", level = vim.log.levels.DEBUG, opts = { title = "docker.nvim" } },
      }, notified)
    end)
  end)
end)
