-- Tests for docker API attach functionality
local helper = require("tests.test_helper")

helper.describe("docker.api attach functionality", {
	["should have attach_container function"] = function()
		local api = require("docker.api")
		helper.assert_not_nil(api.attach_container)
		helper.assert_equal(type(api.attach_container), "function")
	end,

	["should call terminal command for attach"] = function()
		local api = require("docker.api")
		local container_id = "test123"
		local callback_called = false
		local callback_err = nil

		-- Mock vim.cmd, vim.fn.termopen and vim.schedule
		local original_cmd = vim.cmd
		local original_termopen = vim.fn.termopen
		local original_schedule = vim.schedule
		local cmd_calls = {}
		local termopen_called = false
		local termopen_cmd = nil

		vim.cmd = function(cmd)
			table.insert(cmd_calls, cmd)
		end

		vim.fn.termopen = function(cmd)
			termopen_called = true
			termopen_cmd = cmd
		end

		vim.schedule = function(func)
			func() -- Execute immediately for testing
		end

		-- Test attach_container
		api.attach_container(container_id, function(err, data)
			callback_called = true
			callback_err = err
		end)

		-- Restore original functions
		vim.cmd = original_cmd
		vim.fn.termopen = original_termopen
		vim.schedule = original_schedule

		helper.assert_true(callback_called)
		helper.assert_nil(callback_err)
		helper.assert_true(termopen_called)
		helper.assert_not_nil(termopen_cmd)

		-- Check if cmd contains docker exec
		local cmd_str = table.concat(termopen_cmd, " ")
		helper.assert_true(string.find(cmd_str, "docker exec") ~= nil)
		helper.assert_true(string.find(cmd_str, container_id) ~= nil)
	end,
})
