-- Minimal init for the tests. Puts plenary.nvim and this plugin itself on the runtimepath.
-- The location of plenary can be overridden with PLENARY_PATH (CI points it at the clone).
local plenary_path = vim.env.PLENARY_PATH
if plenary_path == nil or plenary_path == "" then
  plenary_path = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
end

--- Report a state where the tests cannot run as a "failure" right away.
--- Without quitting here, PlenaryBusted* stays an undefined command, the headless nvim
--- hangs instead of exiting, and CI sees no response rather than a failure.
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

-- The directory merely existing is not enough (a partial clone, a path at the wrong depth,
-- and other "exists but is not plenary" directories all reach this point too).
-- Confirm that the commands were really defined.
if vim.fn.exists(":PlenaryBustedDirectory") ~= 2 then
  abort("plenary commands not available (is " .. plenary_path .. " really a plenary.nvim checkout?)")
end
