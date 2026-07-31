--- Runs the docker command (one-shot).
---
--- This module is the only one that touches the outside world; the execution itself is delegated
--- to a swappable executor.
--- It never throws: it always returns a `docker.Result` so that callers are forced to check
--- whether the call succeeded.
local format = require("docker.format")
local notify = require("docker.notify")

local M = {}

---@class docker.Result
---@field ok boolean
---@field data any          Parsed data on success
---@field error string|nil  Message on failure (the docker stderr goes in as-is)
---@field code integer|nil  Exit code

---@alias docker.Executor fun(cmd: string[], opts: table, on_exit: fun(out: table))

--- The stderr synthesized when docker is not found.
--- `vim.system` only throws synchronously when the executable is missing and never returns an exit
--- code, so we normalize to this wording to make it detectable as an environment error.
local EXECUTABLE_NOT_FOUND = "docker: executable not found"

local MESSAGE_NOT_INSTALLED =
  "docker コマンドが見つかりません。docker をインストールし PATH を通してください。"
local MESSAGE_DAEMON_DOWN =
  "docker デーモンに接続できません。docker が起動しているか確認してください。"
local MESSAGE_NO_PERMISSION =
  "docker ソケットへのアクセス権限がありません。ユーザーが docker グループに属しているか確認してください。"

---@param haystack string
---@param needle string
---@return boolean
local function contains(haystack, needle)
  return haystack:find(needle, 1, true) ~= nil
end

--- Words that refer to the docker endpoint. Used to confirm that a permission error happened in the
--- context of docker.
--- docker 29 emits wording containing "docker API", 28 and earlier "Docker daemon socket".
local DOCKER_ENDPOINT_HINTS = { "docker api", "docker daemon socket", "docker.sock", "docker_engine" }

---@param stderr string
---@return boolean
local function mentions_docker_endpoint(stderr)
  for _, hint in ipairs(DOCKER_ENDPOINT_HINTS) do
    if contains(stderr, hint) then
      return true
    end
  end
  return false
end

--- Classifies environment errors. The exit code alone cannot tell them apart, so we branch on the
--- content of stderr. Evaluated from top to bottom.
---
--- Note that the wording changes with the docker version (all captured on real machines):
---   28 and earlier / daemon down:   "Cannot connect to the Docker daemon at unix://...
---                                    Is the docker daemon running?"
---   29 / daemon down:               "failed to connect to the docker API at unix://...; check if the path is
---                                    correct and if the daemon is running: ... connect: no such file or directory"
---   28 and earlier / no permission: "Got permission denied while trying to connect to the Docker daemon socket at ..."
---   29 / no permission:             "permission denied while trying to connect to the docker API at unix://..."
--- Matching only the new wording silently breaks the check on old docker, and matching only the old
--- wording silently breaks it on new docker, so we accept both.
local ENVIRONMENT_ERRORS = {
  {
    -- For insufficient permission we also confirm that the message mentions the docker endpoint.
    -- Deciding on `permission denied` alone would misguide the user about
    -- `Permission denied (publickey).`, returned by a docker context over SSH, as a docker group issue.
    matches = function(stderr)
      return contains(stderr, "permission denied") and mentions_docker_endpoint(stderr)
    end,
    message = MESSAGE_NO_PERMISSION,
  },
  {
    matches = function(stderr)
      return contains(stderr, "executable not found") or contains(stderr, "command not found")
    end,
    message = MESSAGE_NOT_INSTALLED,
  },
  {
    matches = function(stderr)
      -- One for 28 and earlier, one for 29. Each wording matches only one of the two, so
      -- dropping either one makes the corresponding test fail (no redundant aliases listed here).
      return contains(stderr, "cannot connect to the docker daemon")
        or contains(stderr, "failed to connect to the docker api")
    end,
    message = MESSAGE_DAEMON_DOWN,
  },
}

---@type docker.Executor|nil
local executor = nil

--- The default executor. Asynchronous execution via vim.system.
--- When docker itself is not found, vim.system throws instead of returning an exit code.
--- Propagating the exception to the caller would break the `docker.Result` contract, so we convert
--- it into a result with exit code 127 here (the only exception to the rule in section 8.3 that
--- pcall is limited to vim.json.decode).
---@type docker.Executor
local function default_executor(cmd, opts, on_exit)
  -- The result of a startup failure is always returned on the next event loop tick. Returning only
  -- this path synchronously would deliver a failure issued later before an execution issued earlier,
  -- swapping the call order and the delivery order (it breaks code written as
  -- "set a flag after cli.run").
  local function fail(stderr)
    vim.schedule(function()
      on_exit({ code = 127, stdout = "", stderr = stderr })
    end)
  end

  -- A missing docker is not the only reason startup fails. A missing working directory fails through
  -- the same path, so we must not misguide the user with "please install docker".
  -- Telling them apart from the exception message would depend on the Neovim version's wording, so
  -- we check the fact directly.
  if opts.cwd and vim.fn.isdirectory(opts.cwd) == 0 then
    fail("docker: working directory not found (" .. tostring(opts.cwd) .. ")")
    return
  end

  local ok, err = pcall(vim.system, cmd, { text = true, cwd = opts.cwd }, function(out)
    on_exit(out)
  end)
  if not ok then
    fail(EXECUTABLE_NOT_FOUND .. " (" .. tostring(err) .. ")")
  end
end

--- Delivers results on the main loop.
--- The on_exit of `vim.system` is called in a fast event context, where many APIs including
--- `vim.notify` fail with `E5560`. Callers (notification, rendering) always hit this constraint, so
--- the adapter layer, being the boundary, absorbs it. In tests that use a synchronous fake executor
--- this is not a fast event, so it runs as-is and can be verified sequentially.
---@param fn fun()
local function deliver(fn)
  if vim.in_fast_event() then
    vim.schedule(fn)
  else
    fn()
  end
end

--- Swap point for tests. Passing nil restores the default executor.
---@param fn docker.Executor|nil
function M._set_executor(fn)
  executor = fn
end

---@param s string|nil
---@return string
local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param stdout string
---@param parse string|nil
---@return string|nil error  Why the output could not be parsed (nil on success)
---@return any data
local function parse_output(stdout, parse)
  if parse == "ndjson" then
    local items, skipped = format.parse_ndjson(stdout)
    if skipped > 0 then
      notify.debug(string.format("skipped %d unparsable line(s)", skipped))
      -- If not a single line could be parsed it is indistinguishable from "0 items", so treat it as an error.
      if #items == 0 then
        return string.format("failed to parse all %d line(s) of docker output", skipped), nil
      end
    end
    return nil, items
  end

  if parse == "json" then
    if not trim(stdout):match("%S") then
      return nil, nil
    end
    local ok, decoded = pcall(vim.json.decode, stdout)
    -- `{{json .X}}` prints null for fields that have no value, so something other than an object or
    -- an array really can come back. Reject it here so that callers can treat data as a table
    -- (aligned with the per-line check on the ndjson side).
    if not ok or type(decoded) ~= "table" then
      return "failed to parse docker output", nil
    end
    return nil, decoded
  end

  return nil, stdout
end

--- Runs docker and returns the outcome as a `docker.Result`.
---@param args string[] Arguments passed to docker ("docker" itself is not included)
---@param on_done fun(result: docker.Result)
---@param opts { parse: "ndjson"|"json"|"raw"|nil, cwd: string|nil }|nil
function M.run(args, on_done, opts)
  opts = opts or {}
  local cmd = { "docker" }
  vim.list_extend(cmd, args)

  local run_with = executor or default_executor
  run_with(cmd, { cwd = opts.cwd }, function(out)
    deliver(function()
      local code = out and out.code
      local signal = out and out.signal

      if notify.is_debug() then
        notify.debug(string.format("%s (exit %s)", table.concat(cmd, " "), tostring(code)))
      end

      -- An execution result that does not report an exit code cannot be regarded as a success.
      if type(code) ~= "number" then
        on_done({ ok = false, data = nil, error = "docker did not report an exit code", code = nil })
        return
      end

      -- A process terminated by a signal can return exit code 0.
      -- Treating that as a success would interpret truncated output as "all items".
      if type(signal) == "number" and signal ~= 0 then
        on_done({
          ok = false,
          data = nil,
          error = string.format("docker was terminated by signal %d", signal),
          code = code,
        })
        return
      end

      if code ~= 0 then
        local message = trim(out.stderr)
        if message == "" then
          message = string.format("docker exited with code %d", code)
        end
        on_done({ ok = false, data = nil, error = message, code = code })
        return
      end

      local parse_error, data = parse_output(out.stdout or "", opts.parse)
      if parse_error then
        on_done({ ok = false, data = nil, error = parse_error, code = code })
        return
      end

      on_done({ ok = true, data = data, error = nil, code = code })
    end)
  end)
end

--- Checks whether the daemon can be reached.
--- On failure it returns wording that distinguishes "docker not found", "daemon not running" and
--- "insufficient socket permission".
---@param on_done fun(result: docker.Result)
function M.check_connection(on_done)
  M.run({ "version", "--format", "{{.Server.Version}}" }, function(result)
    if result.ok then
      on_done({ ok = true, data = trim(result.data), error = nil, code = result.code })
      return
    end

    local stderr = tostring(result.error or ""):lower()
    for _, known in ipairs(ENVIRONMENT_ERRORS) do
      if known.matches(stderr) then
        on_done({ ok = false, data = nil, error = known.message, code = result.code })
        return
      end
    end

    on_done(result)
  end)
end

return M
