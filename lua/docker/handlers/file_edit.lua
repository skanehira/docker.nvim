--- コンテナ内のファイルを Neovim で編集する。
---
--- `docker cp` で一時領域へ取り出し、`docker://<container>/<path>` という名前の
--- バッファで開く。保存は `BufWriteCmd` で横取りして `docker cp` で書き戻す。
--- 書き戻しに失敗したときは `modified` を落とさない (変更を失わせないため)。
local cli = require("docker.adapters.docker.cli")
local notify = require("docker.notify")

local M = {}

--- バッファ番号 -> 書き戻し先
---@type table<integer, { id: string, label: string, path: string, local_path: string }>
local targets = {}

local augroup = vim.api.nvim_create_augroup("DockerNvimFileEdit", { clear = true })

--- テスト用。開いた対応付けを捨てる。
function M._reset()
  targets = {}
end

--- コンテナ内のパスを一時領域へ写す名前を作る。
--- 同じパスを別のコンテナで開いても衝突しないよう ID を混ぜる。
---@param id string
---@param path string
---@return string
local function local_path_for(id, path)
  local safe = path:gsub("[^%w%-_.]", "_")
  return ("%s/docker-nvim-%s-%s"):format(vim.fn.stdpath("cache"), id:sub(1, 12), safe)
end

--- 書き戻す。
---@param bufnr integer
function M.write(bufnr)
  local target = targets[bufnr]
  if not target then
    return
  end

  -- バッファの内容を一時ファイルへ落としてから送る。
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  vim.fn.writefile(lines, target.local_path)

  cli.run({ "cp", target.local_path, ("%s:%s"):format(target.id, target.path) }, function(result)
    if not result.ok then
      -- 失敗したら modified を残す。落とすと変更が失われたように見える。
      notify.error(result.error or "コンテナへの書き戻しに失敗しました")
      return
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.bo[bufnr].modified = false
    end
    notify.info(("%s:%s を保存しました"):format(target.label, target.path))
  end)
end

--- コンテナ内のファイルを開く。取り出しに失敗したときはバッファを開かない。
---@param id string
---@param label string
---@param path string
---@param on_done fun(bufnr: integer|nil)|nil
function M.open(id, label, path, on_done)
  local function done(bufnr)
    if on_done then
      on_done(bufnr)
    end
  end

  local local_path = local_path_for(id, path)
  cli.run({ "cp", ("%s:%s"):format(id, path), local_path }, function(result)
    if not result.ok then
      notify.error(result.error or ("%s を取り出せませんでした"):format(path))
      return done(nil)
    end

    -- `acwrite` は「保存を autocmd で処理する」バッファ種別。
    -- bufadd + bufload だと実在しないパスを読もうとして種別が戻るため、
    -- バッファを自分で作ってから名前と種別を与える。
    -- 同じファイルを 2 回開いたときは既存のバッファを使い回す。
    -- 新しく作って同じ名前を付けると E95 (バッファ名の重複) で落ちる。
    local name = ("docker://%s%s"):format(label, path)
    local existing = vim.fn.bufnr(name)
    local bufnr
    if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
      bufnr = existing
    else
      bufnr = vim.api.nvim_create_buf(true, false)
      local named = pcall(vim.api.nvim_buf_set_name, bufnr, name)
      if not named then
        vim.api.nvim_buf_delete(bufnr, { force = true })
        notify.error(("%s を開けませんでした (バッファ名が衝突しています)"):format(path))
        return done(nil)
      end
    end
    vim.bo[bufnr].buftype = "acwrite"
    vim.bo[bufnr].swapfile = false
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.fn.readfile(local_path))
    vim.bo[bufnr].modified = false

    targets[bufnr] = { id = id, label = label, path = path, local_path = local_path }

    -- 保存を横取りして docker へ書き戻す。
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      group = augroup,
      buffer = bufnr,
      desc = "docker.nvim: コンテナ内のファイルへ書き戻す",
      callback = function()
        M.write(bufnr)
      end,
    })

    vim.api.nvim_win_set_buf(0, bufnr)
    done(bufnr)
  end)
end

return M
