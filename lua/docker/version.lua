--- 対応する Neovim のバージョン判定。
---
--- `vim.system` を使うため 0.10 以上を要求する。要求を満たさない環境では
--- コマンドもキーマップも登録せず、以降どの操作でも実行時エラーを出さない。
--- 起動時に読む必要があるので、このモジュールは他のモジュールに依存しない。
local M = {}

M.MINIMUM = { major = 0, minor = 10 }

---@param v table|nil 省略時は実行中の Neovim
---@return table
local function resolve(v)
  return v or vim.version()
end

--- 要求バージョンを満たすか。
---@param v table|nil
---@return boolean
function M.supported(v)
  local current = resolve(v)
  if current.major ~= M.MINIMUM.major then
    return current.major > M.MINIMUM.major
  end
  return current.minor >= M.MINIMUM.minor
end

--- 要求を満たさないときに通知する文言。
---@param v table|nil
---@return string
function M.requirement_message(v)
  local current = resolve(v)
  return ("docker.nvim は Neovim %d.%d 以上が必要です (現在 %d.%d.%d)"):format(
    M.MINIMUM.major,
    M.MINIMUM.minor,
    current.major,
    current.minor,
    current.patch or 0
  )
end

return M
