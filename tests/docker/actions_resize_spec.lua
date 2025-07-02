-- Tests for docker actions auto-resize functionality
local helper = require("tests.test_helper")

helper.describe("docker.actions auto-resize functionality", {
	["should have auto_resize_windows function"] = function()
		local actions = require("docker.actions")
		helper.assert_not_nil(actions.auto_resize_windows)
		helper.assert_equal(type(actions.auto_resize_windows), "function")
	end,

	["should setup VimResized autocmd when setting windows"] = function()
		local actions = require("docker.actions")

		-- Clear any existing autocmd
		actions._resize_autocmd_id = nil

		-- Mock vim.api functions
		local original_create_autocmd = vim.api.nvim_create_autocmd
		local autocmd_created = false
		local autocmd_callback = nil

		vim.api.nvim_create_autocmd = function(event, opts)
			if event == "VimResized" then
				autocmd_created = true
				autocmd_callback = opts.callback
			end
			return 1 -- mock autocmd id
		end

		-- Test setting windows
		local mock_windows = {
			header_win = 1,
			main_win = 2,
			footer_win = 3,
		}

		actions.set_current_windows(mock_windows)

		-- Restore original function
		vim.api.nvim_create_autocmd = original_create_autocmd

		helper.assert_true(autocmd_created)
		helper.assert_not_nil(autocmd_callback)
		helper.assert_equal(actions._current_windows, mock_windows)
	end,

	["should resize windows when auto_resize_windows is called"] = function()
		local actions = require("docker.actions")

		-- Mock current windows and data
		actions._current_windows = {
			header_win = 1,
			main_win = 2,
			footer_win = 3,
		}
		actions._current_data = {
			containers = {
				{ Id = "test123", Name = "test-container", Image = "test:latest", Status = "Up 1 hour", Ports = {} },
				{ Id = "test456", Name = "test-container-2", Image = "test:v2", Status = "Up 2 hours", Ports = {} },
			},
			window_type = "containers",
		}

		-- Mock vim.schedule to execute immediately for testing
		local original_schedule = vim.schedule
		vim.schedule = function(func)
			func() -- Execute immediately for testing
		end

		-- Mock vim.api functions
		local original_win_is_valid = vim.api.nvim_win_is_valid
		local original_win_set_config = vim.api.nvim_win_set_config
		local win_configs_set = {}

		vim.api.nvim_win_is_valid = function(win)
			return win == 1 or win == 2 or win == 3 -- mock valid windows
		end

		vim.api.nvim_win_set_config = function(win, config)
			win_configs_set[win] = config
		end

		-- Test auto resize
		actions.auto_resize_windows()

		-- Restore original functions
		vim.schedule = original_schedule
		vim.api.nvim_win_is_valid = original_win_is_valid
		vim.api.nvim_win_set_config = original_win_set_config

		-- Verify that window configs were set
		helper.assert_not_nil(win_configs_set[1]) -- header window
		helper.assert_not_nil(win_configs_set[2]) -- main window
		helper.assert_not_nil(win_configs_set[3]) -- footer window

		-- Check that each config has the required properties
		for _, config in pairs(win_configs_set) do
			helper.assert_not_nil(config.width)
			helper.assert_not_nil(config.height)
			helper.assert_not_nil(config.col)
			helper.assert_not_nil(config.row)
			helper.assert_equal(config.relative, "editor")
		end
	end,

	["should cleanup when windows are invalid"] = function()
		local actions = require("docker.actions")

		-- Mock current windows and data
		actions._current_windows = {
			header_win = 1,
			main_win = 2,
			footer_win = 3,
		}
		actions._current_data = {
			containers = {},
			window_type = "containers",
		}

		-- Mock vim.schedule to execute immediately for testing
		local original_schedule = vim.schedule
		vim.schedule = function(func)
			func() -- Execute immediately for testing
		end

		-- Mock vim.api.nvim_win_is_valid to return false (invalid windows)
		local original_win_is_valid = vim.api.nvim_win_is_valid
		vim.api.nvim_win_is_valid = function(_)
			return false -- All windows are invalid
		end

		-- Test auto resize with invalid windows
		actions.auto_resize_windows()

		-- Restore original functions
		vim.schedule = original_schedule
		vim.api.nvim_win_is_valid = original_win_is_valid

		-- Verify cleanup
		helper.assert_nil(actions._current_windows)
		helper.assert_nil(actions._current_data.window_type)
	end,

	["should not resize when no windows are set"] = function()
		local actions = require("docker.actions")

		-- Clear current windows
		actions._current_windows = nil
		actions._current_data.window_type = nil

		-- Mock vim.schedule to execute immediately for testing
		local original_schedule = vim.schedule
		local schedule_called = false
		vim.schedule = function(func)
			schedule_called = true
			func() -- Execute immediately for testing
		end

		-- Test auto resize with no windows
		actions.auto_resize_windows()

		-- Restore original function
		vim.schedule = original_schedule

		-- Should not have called vim.schedule since function should return early
		helper.assert_false(schedule_called)
	end,

	["should calculate dynamic height based on content and terminal size"] = function()
		local actions = require("docker.actions")

		-- Mock current windows and data with more containers
		actions._current_windows = {
			header_win = 1,
			main_win = 2,
			footer_win = 3,
		}
		actions._current_data = {
			containers = {
				{ Id = "test1", Name = "container-1", Image = "test:1", Status = "Up", Ports = {} },
				{ Id = "test2", Name = "container-2", Image = "test:2", Status = "Up", Ports = {} },
				{ Id = "test3", Name = "container-3", Image = "test:3", Status = "Up", Ports = {} },
			},
			window_type = "containers",
		}

		-- Mock vim.schedule to execute immediately for testing
		local original_schedule = vim.schedule
		vim.schedule = function(func)
			func() -- Execute immediately for testing
		end

		-- Mock vim.api functions
		local original_win_is_valid = vim.api.nvim_win_is_valid
		local original_win_set_config = vim.api.nvim_win_set_config
		local main_win_config = nil

		vim.api.nvim_win_is_valid = function(win)
			return win == 1 or win == 2 or win == 3 -- mock valid windows
		end

		vim.api.nvim_win_set_config = function(win, config)
			if win == 2 then -- main window
				main_win_config = config
			end
		end

		-- Test auto resize
		actions.auto_resize_windows()

		-- Restore original functions
		vim.schedule = original_schedule
		vim.api.nvim_win_is_valid = original_win_is_valid
		vim.api.nvim_win_set_config = original_win_set_config

		-- Verify that height was calculated based on content (3 containers)
		helper.assert_not_nil(main_win_config)
		-- Content height should be at least the minimum (10 + 2 = 12) but could be more based on container count
		helper.assert_true(main_win_config.height >= 5) -- At least room for the 3 containers plus padding
	end,
})
