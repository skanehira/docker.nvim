--- アクション名から実処理への振り分け。
---
--- 前提状態の検査 (BR-007) → 重複要求の排除 (BR-009) → docker 実行 の順で進める。
--- 失敗しても内部状態は変えない。一覧は docker のイベント経由で更新される。
local cli = require("docker.adapters.docker.cli")
local notify = require("docker.notify")
local operations = require("docker.handlers.operations")
local terminal = require("docker.handlers.terminal")

local M = {}

---@class docker.ActionContext
---@field def docker.ResourceDefinition
---@field item table|nil

--- 状態を変えるコンテナ操作。
--- `requires` を満たさない状態で呼ばれた場合、docker を呼ばずに警告する。
local CONTAINER_ACTIONS = {
  start = {
    args = "start",
    forbids = { running = true, restarting = true },
    denied = "%s は既に実行中です",
    success = "%s を起動しました",
  },
  stop = {
    args = "stop",
    requires = { running = true, restarting = true },
    denied = "%s は実行中ではないため停止できません",
    success = "%s を停止しました",
  },
  restart = {
    args = "restart",
    success = "%s を再起動しました",
  },
  kill = {
    args = "kill",
    requires = { running = true, restarting = true },
    denied = "%s は実行中ではないため強制終了できません",
    success = "%s を強制終了しました",
  },
}

---@param item table
---@return string
local function label_of(item)
  local name = item.name
  if type(name) == "string" and name ~= "" then
    return name
  end
  return tostring(item.id)
end

---@param spec table
---@param state string
---@return boolean allowed
local function allowed(spec, state)
  if spec.requires and not spec.requires[state] then
    return false
  end
  if spec.forbids and spec.forbids[state] then
    return false
  end
  return true
end

--- 実行中の印を立てて docker を呼び、完了で解除する。
---@param target_id string
---@param label string
---@param operation string
---@param args string[]
---@param success string 成功時の文言 (`%s` に対象名が入る)
local function run_exclusive(target_id, label, operation, args, success)
  if not operations.begin(target_id, operation) then
    notify.warn(("%s の %s は実行中です"):format(label, operation))
    return
  end

  cli.run(args, function(result)
    operations.finish(target_id, operation)
    if result.ok then
      notify.info(success:format(label))
    else
      -- docker の標準エラー出力をそのまま提示する (BR-016)。
      notify.error(result.error or "docker の実行に失敗しました")
    end
  end)
end

--- 確認を経て削除する。`y` と答えたときだけ docker に削除を要求する。
---@param ctx docker.ActionContext
---@param item table
---@param label string
local function delete(ctx, item, label)
  vim.ui.input({ prompt = ("%s を削除しますか? (y/N): "):format(label) }, function(answer)
    if answer ~= "y" and answer ~= "Y" then
      return
    end
    run_exclusive(tostring(item.id), label, "delete", ctx.def.delete_args(item), "%s を削除しました")
  end)
end

--- ターミナルを開く操作。実行中でないコンテナには入れない。
local TERMINAL_ACTIONS = {
  -- 停止中でもログは読めるので前提を課さない。
  logs = { requires = nil },
  shell = { requires = { running = true }, denied = "%s は実行中ではないためシェルを開けません" },
  exec = {
    requires = { running = true },
    denied = "%s は実行中ではないためコマンドを実行できません",
  },
}

---@param name string
---@param item table
---@param label string
local function open_terminal(name, item, label)
  local id = tostring(item.id)
  if name == "logs" then
    terminal.open_logs(id, label)
    return
  end
  if name == "shell" then
    terminal.open_shell(id, label)
    return
  end
  vim.ui.input({ prompt = ("%s で実行するコマンド: "):format(label) }, function(command)
    if type(command) ~= "string" or vim.trim(command) == "" then
      return
    end
    terminal.open_exec(id, label, command)
  end)
end

--- アクションを実行する。
---@param name string
---@param ctx docker.ActionContext
function M.execute(name, ctx)
  local spec = CONTAINER_ACTIONS[name]
  local terminal_spec = TERMINAL_ACTIONS[name]
  if not spec and not terminal_spec and name ~= "delete" then
    notify.warn(("未対応の操作です: %s"):format(tostring(name)))
    return
  end

  local item = ctx.item
  if not item then
    notify.warn("操作の対象がありません")
    return
  end

  local label = label_of(item)

  if name == "delete" then
    delete(ctx, item, label)
    return
  end

  if terminal_spec then
    local state = ctx.def.status(item) or ""
    if terminal_spec.requires and not terminal_spec.requires[state] then
      notify.warn(terminal_spec.denied:format(label))
      return
    end
    open_terminal(name, item, label)
    return
  end
  local state = ctx.def.status(item) or ""
  if not allowed(spec, state) then
    notify.warn(spec.denied:format(label))
    return
  end

  local target_id = tostring(item.id)
  run_exclusive(target_id, label, name, { spec.args, target_id }, spec.success)
end

return M
