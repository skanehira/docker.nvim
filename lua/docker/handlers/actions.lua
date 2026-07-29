--- アクション名から実処理への振り分け。
---
--- 前提状態の検査 (BR-007) → 重複要求の排除 (BR-009) → docker 実行 の順で進める。
--- 失敗しても内部状態は変えない。一覧は docker のイベント経由で更新される。
local cli = require("docker.adapters.docker.cli")
local file_edit = require("docker.handlers.file_edit")
local compose = require("docker.adapters.docker.compose")
local notify = require("docker.notify")
local operations = require("docker.handlers.operations")
local ports = require("docker.resources.ports")
local terminal = require("docker.handlers.terminal")

local M = {}

---@class docker.ActionContext
---@field def docker.ResourceDefinition
---@field item table|nil
---@field cwd string|nil                    compose 操作を実行する作業ディレクトリ (BR-003)
---@field project docker.ComposeProject|nil compose サービス一覧のときのみ

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
  pause = {
    args = "pause",
    requires = { running = true },
    denied = "%s は実行中ではないため一時停止できません",
    success = "%s を一時停止しました",
  },
  unpause = {
    args = "unpause",
    requires = { paused = true },
    denied = "%s は一時停止していません",
    success = "%s の一時停止を解除しました",
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

--- compose のサービス単位の操作。いずれもデタッチで実行する (BR-023)。
local SERVICE_ACTIONS = {
  up = { args = { "up", "-d" }, success = "%s を起動しました" },
  stop = { args = { "stop" }, success = "%s を停止しました" },
  restart = { args = { "restart" }, success = "%s を再起動しました" },
}

--- compose のプロジェクト単位の操作。
local PROJECT_ACTIONS = {
  project_up = { args = { "up", "-d" }, success = "%s を起動しました" },
  project_down = {
    args = { "down" },
    confirm = "%s を破棄しますか? (y/N): ",
    success = "%s を破棄しました",
  },
}

--- 実行中の印を立てて compose を呼び、完了で解除する。
---@param target_id string
---@param label string
---@param operation string
---@param args string[]
---@param cwd string
---@param success string
local function run_compose_exclusive(target_id, label, operation, args, cwd, success)
  if not operations.begin(target_id, operation) then
    notify.warn(("%s の %s は実行中です"):format(label, operation))
    return
  end

  compose.run(args, cwd, function(result)
    operations.finish(target_id, operation)
    if result.ok then
      notify.info(success:format(label))
    else
      notify.error(result.error or "docker compose の実行に失敗しました")
    end
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

--- 使い捨てコンテナで起動する対象。タグが付いていればそちらを使う。
---@param item table
---@return string
local function image_ref(item)
  local repository = tostring(item.repository or "")
  local tag = tostring(item.tag or "")
  if repository ~= "" and repository ~= "<none>" and tag ~= "" and tag ~= "<none>" then
    return ("%s:%s"):format(repository, tag)
  end
  return tostring(item.id)
end

--- 公開ポートをブラウザで開く。複数あれば選ばせる。
---@param item table
---@param label string
local function open_browser(item, label)
  local urls = ports.published(item.ports)
  if #urls == 0 then
    notify.warn(("%s には公開されているポートがありません"):format(label))
    return
  end
  if #urls == 1 then
    vim.ui.open(urls[1])
    return
  end
  vim.ui.select(urls, { prompt = ("%s のどのポートを開きますか?"):format(label) }, function(choice)
    if choice then
      vim.ui.open(choice)
    end
  end)
end

--- 2 つのパスを尋ねてから `docker cp` を実行する。
---@param item table
---@param label string
---@param direction "to"|"from"
local function copy_file(item, label, direction)
  local id = tostring(item.id)
  local first = direction == "to" and "コピー元 (ホスト): " or ("コピー元 (%s 内): "):format(label)
  local second = direction == "to" and ("コピー先 (%s 内): "):format(label) or "コピー先 (ホスト): "

  vim.ui.input({ prompt = first }, function(source)
    if type(source) ~= "string" or vim.trim(source) == "" then
      return
    end
    vim.ui.input({ prompt = second }, function(destination)
      if type(destination) ~= "string" or vim.trim(destination) == "" then
        return
      end
      local from = direction == "to" and source or ("%s:%s"):format(id, source)
      local to = direction == "to" and ("%s:%s"):format(id, destination) or destination
      run_exclusive(id, label, "copy", { "cp", from, to }, "%s のコピーが完了しました")
    end)
  end)
end

--- アクションを実行する。
---@param name string
---@param ctx docker.ActionContext
function M.execute(name, ctx)
  local spec = CONTAINER_ACTIONS[name]
  local terminal_spec = TERMINAL_ACTIONS[name]
  local EXTRA = { quickrun = true, open_browser = true, copy_to = true, copy_from = true, edit_file = true }
  if ctx.def.kind ~= "service" and not spec and not terminal_spec and not EXTRA[name] and name ~= "delete" then
    notify.warn(("未対応の操作です: %s"):format(tostring(name)))
    return
  end

  local item = ctx.item
  if not item then
    notify.warn("操作の対象がありません")
    return
  end

  local label = label_of(item)

  -- compose サービス一覧の操作は docker compose へ振り分ける。
  if ctx.def.kind == "service" then
    local cwd = ctx.cwd or vim.fn.getcwd()
    local project_name = ctx.project and ctx.project.name or tostring(item.project)

    local project_spec = PROJECT_ACTIONS[name]
    if project_spec then
      local args = vim.deepcopy(project_spec.args)
      if project_spec.confirm then
        vim.ui.input({ prompt = project_spec.confirm:format(project_name) }, function(answer)
          if answer ~= "y" and answer ~= "Y" then
            return
          end
          run_compose_exclusive(project_name, project_name, name, args, cwd, project_spec.success)
        end)
        return
      end
      run_compose_exclusive(project_name, project_name, name, args, cwd, project_spec.success)
      return
    end

    local service_spec = SERVICE_ACTIONS[name]
    if service_spec then
      local args = vim.deepcopy(service_spec.args)
      table.insert(args, tostring(item.name))
      run_compose_exclusive(("%s/%s"):format(project_name, item.name), label, name, args, cwd, service_spec.success)
      return
    end

    if name == "logs" then
      -- コンテナが無いサービスにはログが無い。ターミナルを開かず警告する。
      if tostring(item.container_id or "") == "" then
        notify.warn(("%s はコンテナが無いためログを表示できません"):format(label))
        return
      end
      terminal.open_compose_logs(tostring(item.name), label, cwd)
      return
    end

    notify.warn(("未対応の操作です: %s"):format(tostring(name)))
    return
  end

  if name == "delete" then
    delete(ctx, item, label)
    return
  end

  if name == "quickrun" then
    terminal.open_quickrun(image_ref(item), label)
    return
  end

  if name == "open_browser" then
    open_browser(item, label)
    return
  end

  if name == "edit_file" then
    vim.ui.input({ prompt = ("%s 内の編集するファイル: "):format(label) }, function(path)
      if type(path) ~= "string" or vim.trim(path) == "" then
        return
      end
      file_edit.open(tostring(item.id), label, vim.trim(path))
    end)
    return
  end

  if name == "copy_to" or name == "copy_from" then
    copy_file(item, label, name == "copy_to" and "to" or "from")
    return
  end

  if terminal_spec then
    local state = ctx.def.status and ctx.def.status(item) or ""
    if terminal_spec.requires and not terminal_spec.requires[state] then
      notify.warn(terminal_spec.denied:format(label))
      return
    end
    open_terminal(name, item, label)
    return
  end
  local state = ctx.def.status and ctx.def.status(item) or ""
  if not allowed(spec, state) then
    notify.warn(spec.denied:format(label))
    return
  end

  local target_id = tostring(item.id)
  run_exclusive(target_id, label, name, { spec.args, target_id }, spec.success)
end

return M
