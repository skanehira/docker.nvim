--- 公開 API。設定の取り込みとビューの開閉。
local config = require("docker.config")
local lifecycle = require("docker.handlers.lifecycle")
local notify = require("docker.notify")
local registry = require("docker.resources.registry")
local version = require("docker.version")

local M = {}

--- 要求バージョンを満たさない環境では機能を無効にする。
--- 以降どの操作でも実行時エラーを出さないよう、入口で止める。
local disabled = false

--- 利用者設定を取り込む。
--- Neovim が要求バージョン未満なら、メッセージを通知して機能を無効化する。
---@param opts docker.Config|nil
function M.setup(opts)
  if not version.supported() then
    disabled = true
    notify.error(version.requirement_message())
    return
  end

  disabled = false
  config.setup(opts)
end

--- 一覧ビューを開く。
---@param kind string "containers" | "images" | "volumes" | "networks" | "services" のいずれか、または単数形の種別
function M.open(kind)
  if disabled then
    return
  end

  local def = registry.get(kind) or registry.by_subcommand(kind)
  if not def then
    notify.warn(("使い方: :Docker {%s}"):format(table.concat(registry.subcommands(), "|")))
    return
  end

  lifecycle.open(def.kind)
end

--- 開いているビューを閉じる。
function M.close()
  lifecycle.close_all()
end

--- テスト用。無効化の状態を戻す。
function M._reset()
  disabled = false
end

return M
