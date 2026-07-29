--- 利用者への通知を 1 箇所に集約する。
--- 通知の種別は DESIGN_DETAIL_APP.md「6.5 メッセージ方針」に対応する。
local M = {}

local TITLE = "docker.nvim"

local debug_enabled = false

---@param msg string
---@param level integer
local function emit(msg, level)
  vim.notify(msg, level, { title = TITLE })
end

--- デバッグ出力の有効・無効を切り替える (既定は無効)。
---@param enabled boolean
function M.set_debug(enabled)
  debug_enabled = enabled and true or false
end

---@return boolean
function M.is_debug()
  return debug_enabled
end

--- 実行した docker コマンドと終了コード、解析に失敗した行数を出力する。
--- 有効にしたときのみ出力する。
---@param msg string
function M.debug(msg)
  if debug_enabled then
    emit(msg, vim.log.levels.DEBUG)
  end
end

--- 操作の成功を伝える。
---@param msg string
function M.info(msg)
  emit(msg, vim.log.levels.INFO)
end

--- 前提を満たさない操作・重複要求を伝える。
---@param msg string
function M.warn(msg)
  emit(msg, vim.log.levels.WARN)
end

--- 操作の失敗・環境問題を伝える。
---@param msg string
function M.error(msg)
  emit(msg, vim.log.levels.ERROR)
end

return M
