-- Tests for docker API kill functionality
local helper = require("tests.test_helper")

helper.describe("docker.api kill functionality", {
	["should have kill_container function"] = function()
		local api = require("docker.api")
		helper.assert_not_nil(api.kill_container)
		helper.assert_equal(type(api.kill_container), "function")
	end,

	["should call correct kill API endpoint"] = function()
		local api = require("docker.api")
		local container_id = "test123"
		local callback_called = false
		local callback_err = nil

		-- Mock the request function
		local original_request = api.request
		api.request = function(method, path, callback)
			helper.assert_equal(method, "POST")
			helper.assert_equal(path, "/containers/" .. container_id .. "/kill")
			callback_called = true
			callback(nil, nil) -- Simulate successful kill (empty response)
		end

		-- Test kill_container
		api.kill_container(container_id, function(err, data)
			callback_err = err
		end)

		-- Restore original request function
		api.request = original_request

		helper.assert_true(callback_called)
		helper.assert_nil(callback_err)
	end,
})
