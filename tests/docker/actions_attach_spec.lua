-- Tests for docker actions attach functionality
local helper = require("tests.test_helper")

helper.describe("docker.actions attach functionality", {
	["should have attach_container function"] = function()
		local actions = require("docker.actions")
		helper.assert_not_nil(actions.attach_container)
		helper.assert_equal(type(actions.attach_container), "function")
	end,

	["should warn when no container selected for attach"] = function()
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

		-- Test attach with no container selected
		actions.attach_container(1)

		-- Restore original functions
		actions.get_current_container_data = original_get_current_data
		vim.notify = original_notify

		helper.assert_true(notify_called)
		helper.assert_true(string.find(notify_message, "No container selected") ~= nil)
	end,

	["should check if container is running before attach"] = function()
		local actions = require("docker.actions")
		local api = require("docker.api")

		-- Mock get_current_container_data to return container data
		local original_get_current_data = actions.get_current_container_data
		actions.get_current_container_data = function()
			return {
				Id = "abc123456789abcdef",
				Names = { "/test-container" },
				Status = "Exited (0) 1 hour ago", -- Not running
			}
		end

		-- Mock vim.schedule to execute immediately for testing
		local original_schedule = vim.schedule
		vim.schedule = function(func)
			func() -- Execute immediately for testing
		end

		-- Mock vim.notify
		local notify_called = false
		local notify_message = nil
		local original_notify = vim.notify
		vim.notify = function(message, level)
			notify_called = true
			notify_message = message
		end

		-- Test attach with stopped container
		actions.attach_container(1)

		-- Restore original functions
		actions.get_current_container_data = original_get_current_data
		vim.schedule = original_schedule
		vim.notify = original_notify

		helper.assert_true(notify_called)
		helper.assert_true(string.find(notify_message, "not running") ~= nil)
	end,

	["should attach to running container"] = function()
		local actions = require("docker.actions")
		local api = require("docker.api")

		-- Mock get_current_container_data to return running container data
		local original_get_current_data = actions.get_current_container_data
		actions.get_current_container_data = function()
			return {
				Id = "abc123456789abcdef",
				Names = { "/test-container" },
				Status = "Up 2 hours", -- Running
			}
		end

		-- Mock vim.schedule to execute immediately for testing
		local original_schedule = vim.schedule
		vim.schedule = function(func)
			func() -- Execute immediately for testing
		end

		-- Mock api.attach_container
		local original_attach_container = api.attach_container
		local attach_called = false
		local attach_container_id = nil
		api.attach_container = function(container_id, callback)
			attach_called = true
			attach_container_id = container_id
			callback(nil, nil)
		end

		-- Mock close_current_windows
		local original_close_windows = actions.close_current_windows
		actions.close_current_windows = function()
			-- Do nothing for testing
		end

		-- Mock vim.notify
		local notify_messages = {}
		local original_notify = vim.notify
		vim.notify = function(message, level)
			table.insert(notify_messages, message)
		end

		-- Test attach with running container
		actions.attach_container(1)

		-- Restore original functions
		actions.get_current_container_data = original_get_current_data
		api.attach_container = original_attach_container
		actions.close_current_windows = original_close_windows
		vim.schedule = original_schedule
		vim.notify = original_notify

		helper.assert_true(attach_called)
		helper.assert_equal(attach_container_id, "abc123456789") -- First 12 chars

		-- Should have attaching message
		local has_attaching_message = false
		for _, msg in ipairs(notify_messages) do
			if string.find(msg, "Attaching to container") then
				has_attaching_message = true
				break
			end
		end
		helper.assert_true(has_attaching_message)
	end,
})
