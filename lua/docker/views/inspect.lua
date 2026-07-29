--- 詳細ビュー。`docker inspect` の結果を JSON として表示する。
---
--- 一覧の上に `zindex` で重ねるだけで、下層の一覧は触らない。閉じたときに
--- 一覧の内容とカーソル位置がそのまま残る (BR-018)。
local cli = require("docker.adapters.docker.cli")
local notify = require("docker.notify")
local window = require("docker.ui.window")

local M = {}

--- 詳細は一覧より前面、ヘルプよりは背面に置く。
local ZINDEX = 150

--- `docker inspect` の出力は既に整形済みなので、そのまま行に分けて表示する。
--- 解析し直して整形すると外部の整形器が要るうえ、キーの順序も崩れる。
---@param stdout string
---@return string[]
local function to_lines(stdout)
  return vim.split(stdout, "\n", { plain = true, trimempty = true })
end

--- 詳細ビューを開く。取得に失敗したときはビューを開かない。
---@param def docker.ResourceDefinition
---@param item table
---@param on_done fun(handle: docker.Window|nil)|nil
function M.open(def, item, on_done)
  local function done(handle)
    if on_done then
      on_done(handle)
    end
  end

  local id = tostring(def.id(item))
  -- 出力はそのまま表示するが、解析できることは確かめてから開く
  -- (docker がエラーを標準出力へ書く場合に備える)。
  cli.run({ "inspect", id }, function(result)
    if not result.ok then
      notify.error(result.error or "詳細を取得できませんでした")
      return done(nil)
    end

    local raw = type(result.data) == "string" and result.data or ""
    if not pcall(vim.json.decode, raw) then
      notify.error("詳細の出力を解析できませんでした")
      return done(nil)
    end

    local label = item.name
    if type(label) ~= "string" or label == "" then
      label = id
    end

    local handle = window.open({
      title = ("Inspect (%s)"):format(label),
      zindex = ZINDEX,
    })
    window.set_lines(handle, to_lines(raw))
    vim.bo[handle.bufnr].filetype = "json"

    -- `q` で閉じると下層の一覧がそのまま残る。
    vim.keymap.set("n", "q", function()
      window.close(handle)
    end, { buffer = handle.bufnr, nowait = true, silent = true, desc = "docker.nvim: 詳細を閉じる" })

    done(handle)
  end)
end

return M
