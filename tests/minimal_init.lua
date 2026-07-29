-- テスト用の最小 init。plenary.nvim と本プラグイン自体を runtimepath に載せる。
-- plenary の場所は PLENARY_PATH で上書きできる (CI では clone 先を指す)。
local plenary_path = vim.env.PLENARY_PATH
if plenary_path == nil or plenary_path == "" then
  plenary_path = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
end

--- テストを実行できない状態を「失敗」として即座に伝える。
--- ここで終了させないと PlenaryBusted* が未定義コマンドのままヘッドレス nvim が
--- 終了せずハングし、CI からは失敗ではなく無応答に見える。
---@param reason string
local function abort(reason)
  io.stderr:write("minimal_init: " .. reason .. "\n")
  io.stderr:write("set PLENARY_PATH to the directory where plenary.nvim is checked out\n")
  vim.cmd("cquit 1")
end

if vim.fn.isdirectory(plenary_path) == 0 then
  abort("plenary.nvim not found at: " .. plenary_path)
end

vim.opt.rtp:append(plenary_path)
vim.opt.rtp:append(".")

vim.opt.swapfile = false

vim.cmd([[runtime plugin/plenary.vim]])

-- ディレクトリが在るだけでは不十分 (部分 clone・パスの階層違いなど、
-- 「存在するが plenary ではない」ディレクトリを指していてもここまで到達する)。
-- 実際にコマンドが定義されたことまで確認する。
if vim.fn.exists(":PlenaryBustedDirectory") ~= 2 then
  abort("plenary commands not available (is " .. plenary_path .. " really a plenary.nvim checkout?)")
end
