-- Tests for docker.api module empty response handling
local helper = require("tests.test_helper")

-- Test the API module handles empty responses correctly
helper.describe("docker.api empty response handling", {
	["should handle empty response from start_container"] = function()
		local api = require("docker.api")

		-- Mock vim.system to simulate empty response (like 204 No Content)
		local original_system = vim.system

		-- Mock a successful empty response
		vim.system = function(_, _, callback)
			callback({
				code = 0,
				stdout = "", -- Empty response like 204 No Content
				stderr = "",
			})
		end

		local error_result = nil
		local data_result = nil
		local callback_called = false

		api.start_container("test_container", function(err, data)
			error_result = err
			data_result = data
			callback_called = true
		end)

		-- Restore original vim.system
		vim.system = original_system

		-- Verify the callback was called successfully
		helper.assert_true(callback_called)
		helper.assert_nil(error_result)
		helper.assert_nil(data_result) -- Should be nil for empty response
	end,

	["should handle empty response from stop_container"] = function()
		local api = require("docker.api")

		-- Mock vim.system to simulate empty response
		local original_system = vim.system

		vim.system = function(_, _, callback)
			callback({
				code = 0,
				stdout = "", -- Empty response
				stderr = "",
			})
		end

		local error_result = nil
		local data_result = nil
		local callback_called = false

		api.stop_container("test_container", function(err, data)
			error_result = err
			data_result = data
			callback_called = true
		end)

		-- Restore original vim.system
		vim.system = original_system

		-- Verify the callback was called successfully
		helper.assert_true(callback_called)
		helper.assert_nil(error_result)
		helper.assert_nil(data_result)
	end,

	["should handle nil stdout response"] = function()
		local api = require("docker.api")

		-- Mock vim.system to simulate nil stdout
		local original_system = vim.system

		vim.system = function(_, _, callback)
			callback({
				code = 0,
				stdout = nil, -- nil response
				stderr = "",
			})
		end

		local error_result = nil
		local data_result = nil
		local callback_called = false

		api.start_container("test_container", function(err, data)
			error_result = err
			data_result = data
			callback_called = true
		end)

		-- Restore original vim.system
		vim.system = original_system

		-- Verify the callback was called successfully
		helper.assert_true(callback_called)
		helper.assert_nil(error_result)
		helper.assert_nil(data_result)
	end,

	["should still handle JSON responses correctly"] = function()
		local api = require("docker.api")

		-- Mock vim.system to simulate JSON response
		local original_system = vim.system

		vim.system = function(_, _, callback)
			callback({
				code = 0,
				stdout = '[{"Id":"abc123","Names":["/test"],"Image":"nginx:latest"}]',
				stderr = "",
			})
		end

		local error_result = nil
		local data_result = nil
		local callback_called = false

		api.list_containers(function(err, data)
			error_result = err
			data_result = data
			callback_called = true
		end)

		-- Restore original vim.system
		vim.system = original_system

		-- Verify the callback was called successfully
		helper.assert_true(callback_called)
		helper.assert_nil(error_result)
		helper.assert_not_nil(data_result)
		helper.assert_equal(type(data_result), "table")
		helper.assert_equal(data_result[1].Id, "abc123")
	end,

	["should handle invalid JSON with proper error message"] = function()
		local api = require("docker.api")

		-- Mock vim.system to simulate invalid JSON response
		local original_system = vim.system

		vim.system = function(_, _, callback)
			callback({
				code = 0,
				stdout = "invalid json {",
				stderr = "",
			})
		end

		local error_result = nil
		local data_result = nil
		local callback_called = false

		api.list_containers(function(err, data)
			error_result = err
			data_result = data
			callback_called = true
		end)

		-- Restore original vim.system
		vim.system = original_system

		-- Verify the callback was called with error
		helper.assert_true(callback_called)
		helper.assert_not_nil(error_result)
		helper.assert_nil(data_result)
		helper.assert_true(string.find(error_result, "Failed to parse JSON response:") ~= nil)
	end,
})
