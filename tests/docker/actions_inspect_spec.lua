-- Tests for docker actions inspect functionality
local helper = require("tests.test_helper")

helper.describe("docker.actions inspect functionality", {
	["should have inspect_container function"] = function()
		local actions = require("docker.actions")
		helper.assert_not_nil(actions.inspect_container)
		helper.assert_equal(type(actions.inspect_container), "function")
	end,

	["should warn when no container selected for inspect"] = function()
		local actions = require("docker.actions")

		-- Mock get_current_container_data to return nil
		local original_get_current_data = actions.get_current_container_data
		actions.get_current_container_data = function()
			return nil
		end

		-- Mock vim.notify
		local notify_called = false
		local notify_message = nil
		local original_notify = vim.notify
		vim.notify = function(message, level)
			notify_called = true
			notify_message = message
		end

		-- Test inspect with no container selected
		actions.inspect_container(1)

		-- Restore original functions
		actions.get_current_container_data = original_get_current_data
		vim.notify = original_notify

		helper.assert_true(notify_called)
		helper.assert_true(string.find(notify_message, "No container selected") ~= nil)
	end,

	["should call inspect API and create buffer"] = function()
		local actions = require("docker.actions")
		local api = require("docker.api")

		-- Mock get_current_container_data to return container data
		local original_get_current_data = actions.get_current_container_data
		actions.get_current_container_data = function()
			return {
				Id = "abc123456789abcdef",
				Names = {"/test-container"},
				Status = "Up 1 hour"
			}
		end

		-- Mock vim.schedule to execute immediately for testing
		local original_schedule = vim.schedule
		vim.schedule = function(func)
			func() -- Execute immediately for testing
		end

		-- Mock vim.fn.executable to simulate jq not being available
		local original_executable = vim.fn.executable
		vim.fn.executable = function(cmd)
			if cmd == "jq" then
				return 0 -- jq not available
			end
			return original_executable(cmd)
		end

		-- Mock api.inspect_container
		local original_inspect_container = api.inspect_container
		local inspect_called = false
		local inspect_container_id = nil
		api.inspect_container = function(container_id, callback)
			inspect_called = true
			inspect_container_id = container_id
			callback(nil, { Id = container_id, Name = "test-container", State = { Status = "running" } })
		end

		-- Mock close_current_windows
		local original_close_windows = actions.close_current_windows
		local windows_closed = false
		actions.close_current_windows = function()
			windows_closed = true
		end

		-- Mock vim.api functions for buffer creation
		local original_create_buf = vim.api.nvim_create_buf
		local original_buf_set_lines = vim.api.nvim_buf_set_lines
		local original_buf_set_name = vim.api.nvim_buf_set_name
		local original_cmd = vim.cmd
		local original_win_set_buf = vim.api.nvim_win_set_buf

		local buf_created = false
		local lines_set = false
		local window_created = false

		vim.api.nvim_create_buf = function(listed, scratch)
			buf_created = true
			return 1 -- mock buffer id
		end

		vim.api.nvim_buf_set_lines = function(buf, start, end_line, strict_indexing, replacement)
			lines_set = true
		end

		vim.api.nvim_buf_set_name = function(buf, name)
			-- Mock function
		end

		vim.cmd = function(cmd)
			if cmd == "rightbelow vsplit" then
				window_created = true
			end
		end

		vim.api.nvim_win_set_buf = function(win, buf)
			-- Mock function
		end

		-- Mock vim.notify
		local notify_messages = {}
		local original_notify = vim.notify
		vim.notify = function(message, level)
			table.insert(notify_messages, message)
		end

		-- Test inspect with valid container
		actions.inspect_container(1)

		-- Restore original functions
		actions.get_current_container_data = original_get_current_data
		api.inspect_container = original_inspect_container
		vim.schedule = original_schedule
		vim.fn.executable = original_executable
		actions.close_current_windows = original_close_windows
		vim.api.nvim_create_buf = original_create_buf
		vim.api.nvim_buf_set_lines = original_buf_set_lines
		vim.api.nvim_buf_set_name = original_buf_set_name
		vim.cmd = original_cmd
		vim.api.nvim_win_set_buf = original_win_set_buf
		vim.notify = original_notify

		helper.assert_true(inspect_called)
		helper.assert_equal(inspect_container_id, "abc123456789") -- First 12 chars
		helper.assert_true(buf_created)
		helper.assert_true(lines_set)
		helper.assert_true(window_created)
		helper.assert_true(windows_closed)

		-- Should have inspection messages
		local has_inspecting_message = false
		local has_opened_message = false
		for _, msg in ipairs(notify_messages) do
			if string.find(msg, "Inspecting container") then
				has_inspecting_message = true
			elseif string.find(msg, "inspection opened") then
				has_opened_message = true
			end
		end
		helper.assert_true(has_inspecting_message)
		helper.assert_true(has_opened_message)
	end,

	["should use jq for formatting when available"] = function()
		local actions = require("docker.actions")
		local api = require("docker.api")

		-- Mock get_current_container_data to return container data
		local original_get_current_data = actions.get_current_container_data
		actions.get_current_container_data = function()
			return {
				Id = "abc123456789abcdef",
				Names = {"/test-container"},
				Status = "Up 1 hour"
			}
		end

		-- Mock vim.schedule to execute immediately for testing
		local original_schedule = vim.schedule
		vim.schedule = function(func)
			func() -- Execute immediately for testing
		end

		-- Mock vim.fn.executable to simulate jq being available
		local original_executable = vim.fn.executable
		vim.fn.executable = function(cmd)
			if cmd == "jq" then
				return 1 -- jq available
			end
			return original_executable(cmd)
		end

		-- Mock vim.system for jq call
		local original_system = vim.system
		local jq_called = false
		vim.system = function(cmd, opts, callback)
			if cmd[1] == "jq" then
				jq_called = true
				-- Simulate successful jq formatting
				callback({
					code = 0,
					stdout = '{\n  "Id": "abc123456789",\n  "Name": "test-container"\n}',
				})
			else
				return original_system(cmd, opts, callback)
			end
		end

		-- Mock api.inspect_container
		local original_inspect_container = api.inspect_container
		api.inspect_container = function(container_id, callback)
			callback(nil, { Id = container_id, Name = "test-container" })
		end

		-- Mock other required functions
		local original_close_windows = actions.close_current_windows
		actions.close_current_windows = function() end

		local original_create_buf = vim.api.nvim_create_buf
		vim.api.nvim_create_buf = function()
			return 1
		end

		local original_buf_set_lines = vim.api.nvim_buf_set_lines
		vim.api.nvim_buf_set_lines = function() end

		local original_buf_set_name = vim.api.nvim_buf_set_name
		vim.api.nvim_buf_set_name = function() end

		local original_cmd = vim.cmd
		vim.cmd = function() end

		local original_win_set_buf = vim.api.nvim_win_set_buf
		vim.api.nvim_win_set_buf = function() end

		local original_notify = vim.notify
		vim.notify = function() end

		-- Test inspect with jq available
		actions.inspect_container(1)

		-- Restore original functions
		actions.get_current_container_data = original_get_current_data
		api.inspect_container = original_inspect_container
		vim.schedule = original_schedule
		vim.fn.executable = original_executable
		vim.system = original_system
		actions.close_current_windows = original_close_windows
		vim.api.nvim_create_buf = original_create_buf
		vim.api.nvim_buf_set_lines = original_buf_set_lines
		vim.api.nvim_buf_set_name = original_buf_set_name
		vim.cmd = original_cmd
		vim.api.nvim_win_set_buf = original_win_set_buf
		vim.notify = original_notify

		helper.assert_true(jq_called)
	end,
})
