--- 利用者への通知を 1 箇所に集約する。
--- 通知の種別は DESIGN_DETAIL_APP.md「6.5 メッセージ方針」に対応する。
local M = {}

local TITLE = "docker.nvim"

---@param msg string
---@param level integer
local function emit(msg, level)
  vim.notify(msg, level, { title = TITLE })
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
