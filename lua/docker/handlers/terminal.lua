--- ターミナルバッファでのコマンド実行。
---
--- ログ追従・シェル・コマンド実行は入出力を伴うため、単発実行の
--- `adapters/docker/cli.lua` ではなくターミナルジョブとして起動する。
--- 起動したジョブは必ず台帳へ載せる (載せ漏れると `:qa` の後に子プロセスが残る)。
local jobs = require("docker.handlers.jobs")

local M = {}

---@class docker.Terminal
---@field bufnr integer
---@field job_id integer

--- コンテナ内に bash があれば bash、無ければ sh を使う (BR-019)。
--- コンテナ側で判定するため、シェルのスニペットとして渡す。
local SHELL_SNIPPET = "if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi"

---@type (fun(cmd: string[], opts: table): integer|nil)|nil
local opener = nil

--- バッファ番号 -> ジョブ ID
---@type table<integer, integer>
local job_of_buffer = {}

--- テスト用の差し替え口。nil を渡すと実際のターミナル生成に戻る。
---@param fn (fun(cmd: string[], opts: table): integer|nil)|nil
function M._set_opener(fn)
  opener = fn
  job_of_buffer = {}
end

--- 実際のターミナル生成。専用バッファを作ってその中でジョブを起動する。
---@param cmd string[]
---@param opts { title: string }
---@return integer|nil job_id
local function default_opener(cmd, opts)
  vim.cmd("enew")
  local job_id = vim.fn.jobstart(cmd, { term = true })
  if job_id and job_id > 0 then
    vim.api.nvim_buf_set_name(0, ("docker://%s"):format(opts.title))
  end
  return job_id
end

---@param cmd string[]
---@param title string
---@return docker.Terminal
local function open(cmd, title)
  local open_with = opener or default_opener
  local job_id = open_with(cmd, { title = title })
  local bufnr = vim.api.nvim_get_current_buf()

  if type(job_id) == "number" and job_id > 0 then
    jobs.register(job_id)
    job_of_buffer[bufnr] = job_id

    vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
      buffer = bufnr,
      once = true,
      desc = "docker.nvim: ターミナルを閉じたらジョブ台帳から外す",
      callback = function()
        M._on_buffer_closed(bufnr)
      end,
    })
  end

  return { bufnr = bufnr, job_id = job_id }
end

--- バッファが破棄されたときに台帳から外す。
---@param bufnr integer
function M._on_buffer_closed(bufnr)
  local job_id = job_of_buffer[bufnr]
  if job_id then
    jobs.unregister(job_id)
    job_of_buffer[bufnr] = nil
  end
end

--- ログを追従する。
---@param id string
---@param label string
---@return docker.Terminal
function M.open_logs(id, label)
  return open({ "docker", "logs", "-f", id }, ("logs/%s"):format(label))
end

--- コンテナ内でシェルを開く。
---@param id string
---@param label string
---@return docker.Terminal
function M.open_shell(id, label)
  return open({ "docker", "exec", "-it", id, "sh", "-c", SHELL_SNIPPET }, ("shell/%s"):format(label))
end

--- コンテナ内でコマンドを実行する。
---@param id string
---@param label string
---@param command string
---@return docker.Terminal
function M.open_exec(id, label, command)
  local cmd = { "docker", "exec", "-it", id }
  for _, word in ipairs(vim.split(vim.trim(command), "%s+", { trimempty = true })) do
    table.insert(cmd, word)
  end
  return open(cmd, ("exec/%s"):format(label))
end

return M
