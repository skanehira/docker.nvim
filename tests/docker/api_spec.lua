-- Tests for docker.api module
local helper = require("tests.test_helper")

-- Test the API module
helper.describe("docker.api", {
	["should have request function"] = function()
		local api = require("docker.api")
		helper.assert_not_nil(api.request)
		helper.assert_equal(type(api.request), "function")
	end,

	["should have list_containers function"] = function()
		local api = require("docker.api")
		helper.assert_not_nil(api.list_containers)
		helper.assert_equal(type(api.list_containers), "function")
	end,

	["should have start_container function"] = function()
		local api = require("docker.api")
		helper.assert_not_nil(api.start_container)
		helper.assert_equal(type(api.start_container), "function")
	end,

	["should have stop_container function"] = function()
		local api = require("docker.api")
		helper.assert_not_nil(api.stop_container)
		helper.assert_equal(type(api.stop_container), "function")
	end,

	["should have list_images function"] = function()
		local api = require("docker.api")
		helper.assert_not_nil(api.list_images)
		helper.assert_equal(type(api.list_images), "function")
	end,
})
