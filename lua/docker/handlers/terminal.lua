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

---@type (fun(cmd: string[], cwd: string|nil): integer|nil)|nil
local job_starter = nil

--- バッファ番号 -> ジョブ ID
---@type table<integer, integer>
local job_of_buffer = {}

--- バッファ名の重複で `E95` にならないよう通し番号を振る。
local sequence = 0

--- テスト用の差し替え口。ジョブ起動だけを差し替え、ウィンドウとバッファの
--- 用意は本番と同じ経路を通す。nil を渡すと実際のジョブ起動に戻る。
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
  -- 一覧はフロートウィンドウで、そこにフォーカスがある状態で `enew` すると
  -- bufhidden=wipe の一覧バッファが破棄されてしまう。必ず新しいウィンドウを開く。
  vim.cmd("botright new")
  local bufnr = vim.api.nvim_get_current_buf()

  local start = job_starter or default_job_starter
  local job_id = start(cmd, cwd)

  if type(job_id) ~= "number" or job_id <= 0 then
    return { bufnr = bufnr, job_id = job_id }
  end

  -- 名前付けより先に台帳へ載せる。名前が衝突して例外になっても、
  -- 起動済みのジョブを追跡対象から漏らさない。
  jobs.register(job_id)
  job_of_buffer[bufnr] = job_id

  sequence = sequence + 1
  pcall(vim.api.nvim_buf_set_name, bufnr, ("docker://%s/%d"):format(title, sequence))

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    buffer = bufnr,
    once = true,
    desc = "docker.nvim: ターミナルを閉じたらジョブ台帳から外す",
    callback = function()
      M._on_buffer_closed(bufnr)
    end,
  })

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

--- コマンド文字列を語に分ける。引用符で囲んだ部分は 1 語として扱う。
---@param command string
---@return string[]
local function split_command(command)
  -- Lua パターンに交替 (|) が無いため手で走査する。
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

--- compose サービスのログを追従する。
---@param service string
---@param label string
---@param cwd string
---@return docker.Terminal
function M.open_compose_logs(service, label, cwd)
  return open({ "docker", "compose", "logs", "-f", service }, ("logs/%s"):format(label), cwd)
end

--- イメージから使い捨てのコンテナを起動してシェルを開く。
--- `--rm` によりシェルを抜けた時点で自動的に削除される。
---@param image string
---@param label string
---@return docker.Terminal
function M.open_quickrun(image, label)
  return open({ "docker", "run", "--rm", "-it", "--entrypoint", "sh", image }, ("run/%s"):format(label))
end

--- コンテナ内でコマンドを実行する。
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
