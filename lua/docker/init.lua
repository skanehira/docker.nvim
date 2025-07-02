-- docker.nvim main module
local M = {}

-- Module dependencies
local ui = require("docker.ui")
local config = require("docker.config")

-- Initialize plugin
function M.setup(opts)
	config.setup(opts or {})
end

-- Show containers window
function M.show_containers()
	ui.show_containers()
end

-- Show images window
function M.show_images()
	ui.show_images()
end

return M
