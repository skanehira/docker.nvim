--- ジョブ台帳。
---
--- 起動したジョブを 1 箇所で追跡し、Neovim 終了時に一括で止める。
--- 台帳から漏れると `:qa` の後に docker の子プロセスが残る (G13)。
local M = {}

---@type integer[]
local registered = {}

---@type fun(job_id: integer)|nil
local stopper = nil

--- テスト用の差し替え口。nil を渡すと `jobstop` に戻る。
---@param fn fun(job_id: integer)|nil
function M._set_stopper(fn)
  stopper = fn
end

--- テスト用。台帳を空に戻す。
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

--- 起動したジョブを台帳に載せる。
---@param job_id integer
function M.register(job_id)
  if index_of(job_id) then
    return
  end
  table.insert(registered, job_id)
end

--- ジョブを台帳から外す (自然終了・バッファ破棄など)。
---@param job_id integer
function M.unregister(job_id)
  local index = index_of(job_id)
  if index then
    table.remove(registered, index)
  end
end

--- 登録順のジョブ一覧。
---@return integer[]
function M.list()
  return vim.deepcopy(registered)
end

--- 登録された全ジョブを停止して台帳を空にする。
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
