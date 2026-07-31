--- Job ledger.
---
--- Tracks every started job in one place and stops them all when Neovim exits.
--- A job missing from the ledger leaves a docker child process behind after `:qa` (G13).
local M = {}

---@type integer[]
local registered = {}

---@type fun(job_id: integer)|nil
local stopper = nil

--- Injection point for tests. Passing nil restores `jobstop`.
---@param fn fun(job_id: integer)|nil
function M._set_stopper(fn)
  stopper = fn
end

--- For tests. Empties the ledger.
function M._reset()
  registered = {}
end

---@param job_id integer
---@return integer|nil
local function index_of(job_id)
  for index, id in ipairs(registered) do
    if id == job_id then
      return index
    end
  end
  return nil
end

--- Puts a started job on the ledger.
---@param job_id integer
function M.register(job_id)
  if index_of(job_id) then
    return
  end
  table.insert(registered, job_id)
end

--- Removes a job from the ledger (natural exit, buffer wipeout, and so on).
---@param job_id integer
function M.unregister(job_id)
  local index = index_of(job_id)
  if index then
    table.remove(registered, index)
  end
end

--- The registered jobs in registration order.
---@return integer[]
function M.list()
  return vim.deepcopy(registered)
end

--- Stops every registered job and empties the ledger.
function M.stop_all()
  local stop = stopper or vim.fn.jobstop
  for _, job_id in ipairs(registered) do
    pcall(stop, job_id)
  end
  registered = {}
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("DockerNvimJobs", { clear = true }),
  desc = "docker.nvim が起動した子プロセスを Neovim 終了時に残さない",
  callback = function()
    M.stop_all()
  end,
})

return M
