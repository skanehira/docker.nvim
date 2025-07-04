-- Configuration management
local M = {}

-- Default configuration
M.defaults = {
	-- Docker settings
	docker = {
		socket_path = "/var/run/docker.sock",
		timeout = 60000, -- milliseconds (1 minute)
	},

	-- Auto refresh settings
	auto_refresh = {
		enabled = true,
		interval = 5, -- seconds
		only_when_visible = true, -- Only refresh when windows are visible
	},

	-- Keymaps
	keymaps = {
		containers = {
			start = "u",
			stop = "d",
			restart = "r",
			kill = "<C-k>",
			attach = "a",
			remove = "x",
			logs = "l",
			exec = "e",
			inspect = "i",
			quit = "q",
		},
		images = {
			run = "<CR>",
			remove = "x",
			pull = "p",
			inspect = "i",
			quit = "q",
		},
	},
}

-- Current configuration
M.config = {}

-- Setup configuration
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

-- Get configuration value
function M.get(key)
	return M.config[key] or M.defaults[key]
end

return M
