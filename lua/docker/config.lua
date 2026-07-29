--- デフォルト設定・キーマップ定義・利用者設定との合成。
---
--- キーはビュー種別ごとに持つ。同じキーをビュー種別ごとに別のアクションへ
--- 割り当てられるようにするため (BR-015)。
local notify = require("docker.notify")

local M = {}

---@class docker.Config
---@field keymaps table<string, table<string, string>>  ビュー種別 -> アクション名 -> キー
---@field debug boolean

--- 既定のキーマップ。denops-docker.vim の割り当てを踏襲する。
--- `common` は全一覧ビューに適用する。
local DEFAULT_KEYMAPS = {
  common = {
    inspect = "<CR>",
    refresh = "R",
    switch_view = "<Tab>",
    help = "?",
    close = "q",
    filter = "<C-f>",
  },
  container_list = {
    start = "u",
    stop = "d",
    restart = "r",
    kill = "<C-k>",
    pause = "p",
    unpause = "P",
    shell = "a",
    exec = "e",
    logs = "t",
    delete = "<C-d>",
    copy_to = "ct",
    copy_from = "cf",
    edit_file = "E",
    open_browser = "<C-o>",
    drilldown = "gd",
  },
  image_list = {
    quickrun = "r",
    delete = "<C-d>",
    drilldown = "gd",
  },
  volume_list = {
    delete = "<C-d>",
  },
  network_list = {
    delete = "<C-d>",
  },
  service_list = {
    up = "u",
    stop = "d",
    restart = "r",
    logs = "t",
    project_up = "U",
    project_down = "D",
    drilldown = "gd",
  },
}

---@type docker.Config|nil
local current = nil

---@return docker.Config
local function defaults()
  return { keymaps = vim.deepcopy(DEFAULT_KEYMAPS), debug = false }
end

--- テスト用。設定を未設定の状態へ戻す。
function M._reset()
  current = nil
  notify.set_debug(false)
end

--- 利用者設定を既定へ重ねる。未知のビュー種別・アクション名は取り込まずに警告する。
--- キーに false を渡すとその割り当てを無効にする。
---@param opts table|nil
---@return docker.Config
local function merge(opts)
  local merged = defaults()
  if type(opts) ~= "table" then
    return merged
  end

  if opts.debug ~= nil then
    merged.debug = opts.debug and true or false
  end

  if type(opts.keymaps) == "table" then
    for view, bindings in pairs(opts.keymaps) do
      if merged.keymaps[view] == nil then
        notify.warn(("設定に未知のビュー種別があります: %s"):format(tostring(view)))
      elseif type(bindings) == "table" then
        for action, key in pairs(bindings) do
          if merged.keymaps[view][action] == nil then
            notify.warn(
              ("設定に未知のアクション名があります: %s.%s"):format(tostring(view), tostring(action))
            )
          elseif key == false then
            merged.keymaps[view][action] = nil
          else
            merged.keymaps[view][action] = key
          end
        end
      end
    end
  end

  return merged
end

--- 利用者設定を取り込む。
---@param opts table|nil
---@return docker.Config
function M.setup(opts)
  current = merge(opts)
  notify.set_debug(current.debug)
  return current
end

--- 現在の設定。`setup` を呼ぶ前は既定値を返す。
---@return docker.Config
function M.get()
  if not current then
    current = defaults()
  end
  return current
end

return M
