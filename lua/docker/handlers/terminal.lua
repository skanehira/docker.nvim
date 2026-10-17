--- Command execution in a terminal buffer.
---
--- Following logs, shells and command execution involve input/output, so they are started as
--- terminal jobs rather than through `adapters/docker/cli.lua`, which runs one-shot commands.
--- Every started job must be put on the ledger (a missed one leaves a child process behind after `:qa`).
local jobs = require("docker.handlers.jobs")

local M = {}

---@class docker.Terminal
---@field bufnr integer
---@field job_id integer

--- Uses bash when the container has it, and sh otherwise (BR-019).
--- The decision is made inside the container, so it is passed as a shell snippet.
local SHELL_SNIPPET = "if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi"

---@type (fun(cmd: string[], cwd: string|nil): integer|nil)|nil
local job_starter = nil

--- buffer number -> job ID
---@type table<integer, integer>
local job_of_buffer = {}

--- Assigns a serial number so that duplicate buffer names do not raise `E95`.
local sequence = 0

--- Injection point for tests. Only the job start is replaced; setting up the window and buffer
--- goes through the same path as in production. Passing nil restores the real job start.
---@param fn (fun(cmd: string[], cwd: string|nil): integer|nil)|nil
function M._set_job_starter(fn)
  job_starter = fn
  job_of_buffer = {}
end

---@param cmd string[]
---@return integer|nil job_id
local function default_job_starter(cmd, cwd)
  return vim.fn.jobstart(cmd, { term = true, cwd = cwd })
end

---@param cmd string[]
---@param title string
---@param cwd string|nil
---@return docker.Terminal
local function open(cmd, title, cwd)
  -- The list is a float window, and running `enew` while it has focus wipes out the
  -- list buffer, which is bufhidden=wipe. Always open a new window.
  vim.cmd("tabnew")
  local bufnr = vim.api.nvim_get_current_buf()

  local start = job_starter or default_job_starter
  local job_id = start(cmd, cwd)

  if type(job_id) ~= "number" or job_id <= 0 then
    return { bufnr = bufnr, job_id = job_id }
  end

  -- Put it on the ledger before naming it. Even if the name collides and raises,
  -- an already started job is never dropped from tracking.
  jobs.register(job_id)
  job_of_buffer[bufnr] = job_id

  sequence = sequence + 1
  pcall(vim.api.nvim_buf_set_name, bufnr, ("docker://%s/%d"):format(title, sequence))

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    buffer = bufnr,
    once = true,
    desc = "docker.nvim: drop the job from the ledger when the terminal closes",
    callback = function()
      M._on_buffer_closed(bufnr)
    end,
  })

  return { bufnr = bufnr, job_id = job_id }
end

--- Removes the job from the ledger when the buffer is wiped out.
---@param bufnr integer
function M._on_buffer_closed(bufnr)
  local job_id = job_of_buffer[bufnr]
  if job_id then
    jobs.unregister(job_id)
    job_of_buffer[bufnr] = nil
  end
end

--- Splits a command string into words. A quoted section is treated as a single word.
---@param command string
---@return string[]
local function split_command(command)
  -- Lua patterns have no alternation (|), so the scan is done by hand.
  local words = {}
  local i = 1
  local length = #command
  while i <= length do
    local char = command:sub(i, i)
    if char:match("%s") then
      i = i + 1
    elseif char == "'" or char == '"' then
      local closing = command:find(char, i + 1, true)
      if closing then
        table.insert(words, command:sub(i + 1, closing - 1))
        i = closing + 1
      else
        table.insert(words, command:sub(i + 1))
        break
      end
    else
      local next_space = command:find("%s", i) or (length + 1)
      table.insert(words, command:sub(i, next_space - 1))
      i = next_space
    end
  end
  return words
end

--- Follows the logs.
---@param id string
---@param label string
---@return docker.Terminal
function M.open_logs(id, label)
  return open({ "docker", "logs", "-f", id }, ("logs/%s"):format(label))
end

--- Opens a shell inside the container.
---@param id string
---@param label string
---@return docker.Terminal
function M.open_shell(id, label)
  return open({ "docker", "exec", "-it", id, "sh", "-c", SHELL_SNIPPET }, ("shell/%s"):format(label))
end

--- Follows the logs of a compose service.
--- The project is named explicitly, so this does not have to run where the compose file is.
---@param project string
---@param service string
---@param label string
---@return docker.Terminal
function M.open_compose_logs(project, service, label)
  return open({ "docker", "compose", "-p", project, "logs", "-f", service }, ("logs/%s"):format(label))
end

--- Starts a throwaway container from an image and opens a shell in it.
--- Thanks to `--rm` it is removed automatically as soon as the shell is left.
---@param image string
---@param label string
---@return docker.Terminal
function M.open_quickrun(image, label)
  return open({ "docker", "run", "--rm", "-it", "--entrypoint", "sh", image }, ("run/%s"):format(label))
end

--- Runs a command inside the container.
---@param id string
---@param label string
---@param command string
---@return docker.Terminal
function M.open_exec(id, label, command)
  local cmd = { "docker", "exec", "-it", id }
  vim.list_extend(cmd, split_command(command))
  return open(cmd, ("exec/%s"):format(label))
end

return M
