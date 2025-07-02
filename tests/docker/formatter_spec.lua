-- Tests for container/image formatting
local helper = require("tests.test_helper")

helper.describe("docker.formatter", {
	["should format container table"] = function()
		local formatter = require("docker.formatter")

		local containers = helper.mock_containers
		local result = formatter.format_containers_table(containers)

		helper.assert_not_nil(result)
		helper.assert_equal(type(result), "table")
		helper.assert_true(#result >= 1) -- Container rows

		-- Check that container data is formatted correctly
		local has_container_data = false
		for _, line in ipairs(result) do
			-- Look for indicator + container ID pattern
			if string.match(line, "^[● ] [a-f0-9]+") then
				has_container_data = true
				break
			end
		end
		helper.assert_true(has_container_data)

		-- Test header separately
		local header_result = formatter.format_containers_header()
		helper.assert_not_nil(header_result)
		helper.assert_true(#header_result >= 1)

		-- Check new header format
		local header_line = header_result[1]
		helper.assert_true(string.find(header_line, "ID") ~= nil)
		helper.assert_true(string.find(header_line, "NAME") ~= nil)
		helper.assert_true(string.find(header_line, "IMAGE") ~= nil)
	end,

	["should format container ID correctly"] = function()
		local formatter = require("docker.formatter")

		local id = formatter.format_container_id("abc123456789def")
		helper.assert_equal(id, "abc123456789")
	end,

	["should format container name correctly"] = function()
		local formatter = require("docker.formatter")

		local name = formatter.format_container_name("/nginx-app")
		helper.assert_equal(name, "nginx-app")
	end,

	["should format image name with truncation"] = function()
		local formatter = require("docker.formatter")

		local short_name = formatter.format_image_name("nginx:latest")
		helper.assert_equal(short_name, "nginx:latest")

		local long_name = formatter.format_image_name("very-long-image-name-that-exceeds-twenty-chars:latest")
		helper.assert_equal(long_name, "very-long-image-name...")
	end,

	["should format port information"] = function()
		local formatter = require("docker.formatter")

		local port_with_public = {
			PublicPort = 8080,
			PrivatePort = 80,
			Type = "tcp",
			IP = "0.0.0.0",
		}

		local port_private_only = {
			PrivatePort = 5432,
			Type = "tcp",
		}

		local public_result = formatter.format_port(port_with_public)
		helper.assert_equal(public_result, "0.0.0.0:8080->80/tcp")

		local private_result = formatter.format_port(port_private_only)
		helper.assert_equal(private_result, "5432/tcp")
	end,

	["should format created date"] = function()
		local formatter = require("docker.formatter")

		local timestamp = 1672531200 -- 2023-01-01 00:00:00 UTC
		local result = formatter.format_created_date(timestamp)

		helper.assert_not_nil(result)
		helper.assert_equal(type(result), "string")
		helper.assert_true(string.match(result, "%d%d%d%d/%d%d/%d%d %d%d:%d%d:%d%d") ~= nil)
	end,
})
