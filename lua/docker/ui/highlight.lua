--- 状態カラムのハイライト。
---
--- グループは既存のハイライトへリンクさせる。配色を直接指定すると利用者の
--- カラースキームと衝突するため、意味の近い標準グループに寄せる。
local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("docker_nvim_highlight")

local UNKNOWN_GROUP = "DockerStatusUnknown"

--- 状態 -> ハイライトグループ。
local GROUPS = {
  running = "DockerStatusRunning",
  exited = "DockerStatusExited",
  paused = "DockerStatusPaused",
  created = "DockerStatusCreated",
  restarting = "DockerStatusRestarting",
  dead = "DockerStatusDead",
  none = "DockerStatusNone",
}

--- グループ -> リンク先の標準ハイライト。
local LINKS = {
  DockerStatusRunning = "DiagnosticOk",
  DockerStatusExited = "Comment",
  DockerStatusPaused = "DiagnosticWarn",
  DockerStatusCreated = "DiagnosticHint",
  DockerStatusRestarting = "DiagnosticWarn",
  DockerStatusDead = "DiagnosticError",
  DockerStatusNone = "Comment",
  [UNKNOWN_GROUP] = "Normal",
}

--- カラム見出しの配色。状態のグループと違い、意味の近い標準グループが無いため
--- 参照元の denops-docker.vim と同じ色を直接指定する。
--- 太字と下線は付けない (denops-docker.vim は cterm にしか指定しておらず、
--- termguicolors 環境では色だけが乗るため、その見た目に合わせる)。
local HEADER_GROUP = "DockerHeader"
local HEADER_HL = { fg = "#e2a478", ctermfg = 216 }

---@return integer
function M.namespace()
  return NAMESPACE
end

--- カラム見出しのハイライトグループ名。
---@return string
function M.header_group()
  return HEADER_GROUP
end

--- ハイライトグループを定義する。既に利用者が定義していれば上書きしない。
function M.setup()
  for group, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
  vim.api.nvim_set_hl(0, HEADER_GROUP, vim.tbl_extend("force", HEADER_HL, { default = true }))
end

--- 状態に対応するハイライトグループ名を返す。
---@param state string|nil
---@return string
function M.group_for(state)
  if type(state) ~= "string" then
    return UNKNOWN_GROUP
  end
  return GROUPS[state:lower()] or UNKNOWN_GROUP
end

--- 指定した行のバイト範囲にハイライトを付ける。
--- 範囲が空のときは何もしない (長さ 0 の extmark は意味を持たない)。
---@param bufnr integer
---@param line integer 0 始まりの行番号
---@param from integer 開始バイト位置
---@param to integer   終了バイト位置 (この位置は含まない)
---@param group string
function M.apply(bufnr, line, from, to, group)
  if to <= from then
    return
  end
  vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, line, from, {
    end_col = to,
    hl_group = group,
  })
end

--- このプラグインが付けたハイライトをすべて消す。
---@param bufnr integer
function M.clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
end

return M
