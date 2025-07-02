-- Tests for docker actions buffer data functionality
local helper = require("tests.test_helper")

helper.describe("docker.actions buffer data functionality", {
	["should have get_current_container_data function"] = function()
		local actions = require("docker.actions")
		helper.assert_not_nil(actions.get_current_container_data)
		helper.assert_equal(type(actions.get_current_container_data), "function")
	end,

	["should have get_current_image_data function"] = function()
		local actions = require("docker.actions")
		helper.assert_not_nil(actions.get_current_image_data)
		helper.assert_equal(type(actions.get_current_image_data), "function")
	end,

	["should return nil when no buffer data exists"] = function()
		local actions = require("docker.actions")

		-- Mock vim.api functions
		local original_get_current_buf = vim.api.nvim_get_current_buf
		local original_win_get_cursor = vim.api.nvim_win_get_cursor

		vim.api.nvim_get_current_buf = function()
			return 1 -- mock buffer id
		end

		vim.api.nvim_win_get_cursor = function()
			return { 3, 0 } -- line 3, column 0
		end

		-- Mock vim.b to return no data
		local original_vim_b = vim.b
		vim.b = {
			[1] = {}, -- empty buffer data
		}

		local container_data = actions.get_current_container_data()
		local image_data = actions.get_current_image_data()

		-- Restore original functions
		vim.api.nvim_get_current_buf = original_get_current_buf
		vim.api.nvim_win_get_cursor = original_win_get_cursor
		vim.b = original_vim_b

		helper.assert_nil(container_data)
		helper.assert_nil(image_data)
	end,

	["should return container data based on cursor line"] = function()
		local actions = require("docker.actions")

		-- Mock container data
		local mock_containers = {
			{ Id = "container1abc123", Names = { "/test-container-1" }, Status = "Up 1 hour" },
			{ Id = "container2def456", Names = { "/test-container-2" }, Status = "Up 2 hours" },
			{ Id = "container3ghi789", Names = { "/test-container-3" }, Status = "Exited (0)" },
		}

		-- Mock vim.api functions
		local original_get_current_buf = vim.api.nvim_get_current_buf
		local original_win_get_cursor = vim.api.nvim_win_get_cursor

		vim.api.nvim_get_current_buf = function()
			return 1 -- mock buffer id
		end

		vim.api.nvim_win_get_cursor = function()
			return { 2, 0 } -- line 2 (should get container at index 2)
		end

		-- Mock vim.b with container data
		local original_vim_b = vim.b
		vim.b = {
			[1] = {
				docker_containers = mock_containers,
			},
		}

		local container_data = actions.get_current_container_data()

		-- Restore original functions
		vim.api.nvim_get_current_buf = original_get_current_buf
		vim.api.nvim_win_get_cursor = original_win_get_cursor
		vim.b = original_vim_b

		helper.assert_not_nil(container_data)
		helper.assert_equal(container_data.Id, "container2def456")
		helper.assert_equal(container_data.Names[1], "/test-container-2")
	end,

	["should return nil for invalid cursor positions"] = function()
		local actions = require("docker.actions")

		-- Mock container data
		local mock_containers = {
			{ Id = "container1abc123", Names = { "/test-container-1" }, Status = "Up 1 hour" },
		}

		-- Mock vim.api functions
		local original_get_current_buf = vim.api.nvim_get_current_buf
		local original_win_get_cursor = vim.api.nvim_win_get_cursor

		vim.api.nvim_get_current_buf = function()
			return 1 -- mock buffer id
		end

		-- Mock vim.b with container data
		local original_vim_b = vim.b
		vim.b = {
			[1] = {
				docker_containers = mock_containers,
			},
		}

		-- Test out of bounds line (line 0, invalid)
		vim.api.nvim_win_get_cursor = function()
			return { 0, 0 } -- line 0 (invalid)
		end
		local container_data_invalid = actions.get_current_container_data()

		-- Test out of bounds line (line 2, but only 1 container)
		vim.api.nvim_win_get_cursor = function()
			return { 2, 0 } -- line 2 (out of bounds, only 1 container)
		end
		local container_data_oob = actions.get_current_container_data()

		-- Restore original functions
		vim.api.nvim_get_current_buf = original_get_current_buf
		vim.api.nvim_win_get_cursor = original_win_get_cursor
		vim.b = original_vim_b

		helper.assert_nil(container_data_invalid)
		helper.assert_nil(container_data_oob)
	end,

	["should maintain backward compatibility with get_current_container"] = function()
		local actions = require("docker.actions")

		-- Mock container data with proper 12+ character ID
		local mock_containers = {
			{ Id = "container1abc123456789abcdef", Names = { "/test-container-1" }, Status = "Up 1 hour" },
		}

		-- Mock vim.api functions
		local original_get_current_buf = vim.api.nvim_get_current_buf
		local original_win_get_cursor = vim.api.nvim_win_get_cursor

		vim.api.nvim_get_current_buf = function()
			return 1 -- mock buffer id
		end

		vim.api.nvim_win_get_cursor = function()
			return { 1, 0 } -- line 1 (first data line in main window)
		end

		-- Mock vim.b with container data
		local original_vim_b = vim.b
		vim.b = {
			[1] = {
				docker_containers = mock_containers,
			},
		}

		local container_id = actions.get_current_container()

		-- Restore original functions
		vim.api.nvim_get_current_buf = original_get_current_buf
		vim.api.nvim_win_get_cursor = original_win_get_cursor
		vim.b = original_vim_b

		helper.assert_not_nil(container_id)
		helper.assert_equal(container_id, "container1ab") -- Should return first 12 characters
		helper.assert_equal(#container_id, 12)
	end,
})
