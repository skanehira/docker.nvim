-- Tests for docker API inspect functionality
local helper = require("tests.test_helper")

helper.describe("docker.api inspect functionality", {
	["should have inspect_container function"] = function()
		local api = require("docker.api")
		helper.assert_not_nil(api.inspect_container)
		helper.assert_equal(type(api.inspect_container), "function")
	end,

	["should call correct inspect API endpoint"] = function()
		local api = require("docker.api")
		local container_id = "test123"
		local callback_called = false
		local callback_err = nil
		local callback_data = nil

		-- Mock the request function
		local original_request = api.request
		api.request = function(method, path, callback)
			helper.assert_equal(method, "GET")
			helper.assert_equal(path, "/containers/" .. container_id .. "/json")
			callback(nil, { Id = container_id, Name = "test-container" })
		end

		-- Test inspect_container
		api.inspect_container(container_id, function(err, data)
			callback_called = true
			callback_err = err
			callback_data = data
		end)

		-- Restore original function
		api.request = original_request

		helper.assert_true(callback_called)
		helper.assert_nil(callback_err)
		helper.assert_not_nil(callback_data)
		helper.assert_equal(callback_data.Id, container_id)
	end,
})
