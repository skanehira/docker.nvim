-- Docker container/image actions
local M = {}

local api = require("docker.api")
local config = require("docker.config")

-- Parse container ID from table line
function M.parse_container_id_from_line(line)
	if not line or line == "" then
		return nil
	end

	-- Skip header and separator lines
	if string.find(line, "ID") or string.find(line, "NAME") or string.find(line, "─") then
		return nil
	end

	-- New format: "● abc123456789 nginx-container             nginx:latest             Up 2 hours           2h              8080->80/tcp"
	--          or "  abc123456789 nginx-container             nginx:latest             Exited (0) 2 hours   2h              -"
	-- Handle both running (●) and stopped (space) containers
	local trimmed
	if line:sub(1, 1) == " " then
		-- Line starts with spaces (stopped container)
		trimmed = line:sub(3) -- Skip "  "
	else
		-- Line starts with UTF-8 bullet (running container)
		trimmed = line:sub(5) -- Skip "● " (UTF-8 bullet + space)
	end

	-- Container ID is the first field after the indicator
	local container_id = string.match(trimmed, "^([a-f0-9]+)")

	if container_id and #container_id == 12 then
		return container_id
	end

	return nil
end

-- Get container ID from current cursor position
function M.get_current_container()
	local line = vim.api.nvim_get_current_line()
	return M.parse_container_id_from_line(line)
end

-- Start container action
function M.start_container(buf)
	local container_id = M.get_current_container()
	if not container_id then
		vim.notify("No container selected", vim.log.levels.WARN)
		return
	end

	vim.notify("Starting container " .. container_id .. "...", vim.log.levels.INFO)

	api.start_container(container_id, function(err, data)
		vim.schedule(function()
			if err then
				vim.notify("Failed to start container: " .. tostring(err), vim.log.levels.ERROR)
				return
			end

			vim.notify("Container " .. container_id .. " started successfully", vim.log.levels.INFO)
		end)

		-- Refresh container list
		M.refresh_containers(buf)
	end)
end

-- Stop container action
function M.stop_container(buf)
	local container_id = M.get_current_container()
	if not container_id then
		vim.notify("No container selected", vim.log.levels.WARN)
		return
	end

	vim.notify("Stopping container " .. container_id .. "...", vim.log.levels.INFO)

	api.stop_container(container_id, function(err)
		vim.schedule(function()
			if err then
				vim.notify("Failed to stop container: " .. err, vim.log.levels.ERROR)
				return
			end

			vim.notify("Container " .. container_id .. " stopped successfully", vim.log.levels.INFO)
		end)

		-- Refresh container list
		M.refresh_containers(buf)
	end)
end

-- Restart container action
function M.restart_container(buf)
	local container_id = M.get_current_container()
	if not container_id then
		vim.notify("No container selected", vim.log.levels.WARN)
		return
	end

	vim.notify("Restarting container " .. container_id .. "...", vim.log.levels.INFO)

	api.restart_container(container_id, function(err)
		vim.schedule(function()
			if err then
				vim.notify("Failed to restart container: " .. err, vim.log.levels.ERROR)
				return
			end

			vim.notify("Container " .. container_id .. " restarted successfully", vim.log.levels.INFO)
		end)

		-- Refresh container list
		M.refresh_containers(buf)
	end)
end

-- Kill container action
function M.kill_container(buf)
	local container_id = M.get_current_container()
	if not container_id then
		vim.notify("No container selected", vim.log.levels.WARN)
		return
	end

	vim.notify("Killing container " .. container_id .. "...", vim.log.levels.INFO)

	api.kill_container(container_id, function(err)
		vim.schedule(function()
			if err then
				vim.notify("Failed to kill container: " .. err, vim.log.levels.ERROR)
				return
			end

			vim.notify("Container " .. container_id .. " killed successfully", vim.log.levels.INFO)
		end)

		-- Refresh container list
		M.refresh_containers(buf)
	end)
end

-- Attach to container action
function M.attach_container(buf)
	local container_id = M.get_current_container()
	if not container_id then
		vim.notify("No container selected", vim.log.levels.WARN)
		return
	end

	-- Check if container is running
	api.list_containers(function(err, containers)
		vim.schedule(function()
			if err then
				vim.notify("Failed to check container status: " .. err, vim.log.levels.ERROR)
				return
			end

			local container = nil
			for _, c in ipairs(containers or {}) do
				if c.Id:sub(1, 12) == container_id then
					container = c
					break
				end
			end

			if not container then
				vim.notify("Container not found or not running", vim.log.levels.WARN)
				return
			end

			-- Check if container is running
			if not string.find(container.Status:lower(), "up") then
				vim.notify("Container is not running. Start it first.", vim.log.levels.WARN)
				return
			end

			vim.notify("Attaching to container " .. container_id .. "...", vim.log.levels.INFO)

			-- Close current floating windows before opening terminal
			M.close_current_windows()

			api.attach_container(container_id, function(err)
				if err then
					vim.schedule(function()
						vim.notify("Failed to attach to container: " .. err, vim.log.levels.ERROR)
					end)
				end
			end)
		end)
	end)
end

-- Inspect container action
function M.inspect_container(buf)
	local container_id = M.get_current_container()
	if not container_id then
		vim.notify("No container selected", vim.log.levels.WARN)
		return
	end

	vim.notify("Inspecting container " .. container_id .. "...", vim.log.levels.INFO)

	api.inspect_container(container_id, function(err, data)
		vim.schedule(function()
			if err then
				vim.notify("Failed to inspect container: " .. err, vim.log.levels.ERROR)
				return
			end

			if not data then
				vim.notify("No inspection data received", vim.log.levels.WARN)
				return
			end

			-- Create a new buffer to show the inspection data
			local inspect_buf = vim.api.nvim_create_buf(false, true)
			vim.bo[inspect_buf].buftype = "nofile"
			vim.bo[inspect_buf].swapfile = false
			vim.bo[inspect_buf].bufhidden = "wipe"
			vim.bo[inspect_buf].filetype = "json"

			-- Check if jq is available
			local jq_available = vim.fn.executable("jq") == 1

			if jq_available then
				-- Use jq for better JSON formatting
				local json_string = vim.json.encode(data)
				vim.system({ "jq", "." }, {
					stdin = json_string,
					text = true,
				}, function(result)
					vim.schedule(function()
						local formatted_lines
						if result.code == 0 and result.stdout then
							formatted_lines = vim.split(vim.trim(result.stdout), "\n")
						else
							-- Fallback to manual formatting if jq fails
							formatted_lines = M._format_json_manually(data)
						end

						-- Set the buffer content
						vim.api.nvim_buf_set_lines(inspect_buf, 0, -1, false, formatted_lines)
						vim.bo[inspect_buf].modifiable = false

						-- Close container list and open the buffer in a new window
						M.close_current_windows()
						vim.cmd("rightbelow vsplit")
						vim.api.nvim_win_set_buf(0, inspect_buf)

						-- Set window title
						vim.api.nvim_buf_set_name(inspect_buf, "Container Inspect: " .. container_id)

						vim.notify("Container inspection opened in new window", vim.log.levels.INFO)
					end)
				end)
			else
				-- Fallback to manual formatting when jq is not available
				local formatted_lines = M._format_json_manually(data)

				-- Set the buffer content
				vim.api.nvim_buf_set_lines(inspect_buf, 0, -1, false, formatted_lines)
				vim.bo[inspect_buf].modifiable = false

				-- Close container list and open the buffer in a new window
				M.close_current_windows()
				vim.cmd("rightbelow vsplit")
				vim.api.nvim_win_set_buf(0, inspect_buf)

				-- Set window title
				vim.api.nvim_buf_set_name(inspect_buf, "Container Inspect: " .. container_id)

				vim.notify(
					"Container inspection opened in new window (jq not available, using fallback formatting)",
					vim.log.levels.INFO
				)
			end
		end)
	end)
end

-- Helper function for manual JSON formatting (fallback when jq is not available)
function M._format_json_manually(data)
	local json_lines = vim.split(vim.json.encode(data), "\n")

	-- Pretty format JSON with proper indentation
	local formatted_json = {}
	local indent_level = 0
	for _, line in ipairs(json_lines) do
		local trimmed = vim.trim(line)
		if trimmed:match("^[}%]]") then
			indent_level = math.max(0, indent_level - 1)
		end

		local indented_line = string.rep("  ", indent_level) .. trimmed
		table.insert(formatted_json, indented_line)

		if trimmed:match("[{%[]$") then
			indent_level = indent_level + 1
		end
	end

	return formatted_json
end

-- Remove container action
function M.remove_container(buf)
	local container_id = M.get_current_container()
	if not container_id then
		vim.notify("No container selected", vim.log.levels.WARN)
		return
	end

	vim.notify("Removing container " .. container_id .. "...", vim.log.levels.INFO)

	api.remove_container(container_id, function(err)
		vim.schedule(function()
			if err then
				vim.notify("Failed to remove container: " .. err, vim.log.levels.ERROR)
				return
			end

			vim.notify("Container " .. container_id .. " removed successfully", vim.log.levels.INFO)
		end)

		-- Refresh container list
		M.refresh_containers(buf)
	end)
end

-- Store current windows for refresh operations
M._current_windows = nil

-- Store current data for auto-resize functionality
M._current_data = {
	containers = nil,
	images = nil,
	window_type = nil, -- "containers" or "images"
}

-- Refresh containers in buffer
function M.refresh_containers(buf)
	vim.schedule(function()
		-- Close current windows and recreate them with proper width
		M.close_current_windows()

		-- Re-open containers window which will recalculate width dynamically
		local ui = require("docker.ui")
		ui.show_containers()
	end)
end

-- Setup keymaps for container buffer
function M.setup_container_keymaps(buf)
	local keymaps = config.get("keymaps").containers

	-- Start container
	vim.keymap.set("n", keymaps.start, function()
		M.start_container(buf)
	end, { buffer = buf, desc = "Start container" })

	-- Stop container
	vim.keymap.set("n", keymaps.stop, function()
		M.stop_container(buf)
	end, { buffer = buf, desc = "Stop container" })

	-- Restart container
	vim.keymap.set("n", keymaps.restart, function()
		M.restart_container(buf)
	end, { buffer = buf, desc = "Restart container" })

	-- Kill container
	vim.keymap.set("n", keymaps.kill, function()
		M.kill_container(buf)
	end, { buffer = buf, desc = "Kill container" })

	-- Attach to container
	vim.keymap.set("n", keymaps.attach, function()
		M.attach_container(buf)
	end, { buffer = buf, desc = "Attach to container" })

	-- Inspect container
	vim.keymap.set("n", keymaps.inspect, function()
		M.inspect_container(buf)
	end, { buffer = buf, desc = "Inspect container" })

	-- Remove container
	vim.keymap.set("n", keymaps.remove, function()
		M.remove_container(buf)
	end, { buffer = buf, desc = "Remove container" })

	-- Quit window
	vim.keymap.set("n", keymaps.quit, function()
		M.close_current_windows()
	end, { buffer = buf, desc = "Quit window" })

	-- Refresh
	vim.keymap.set("n", "R", function()
		M.refresh_containers(buf)
	end, { buffer = buf, desc = "Refresh containers" })
end

-- Setup keymaps for image buffer
function M.setup_image_keymaps(buf)
	local keymaps = config.get("keymaps").images

	-- Quit window
	vim.keymap.set("n", keymaps.quit, function()
		M.close_current_windows()
	end, { buffer = buf, desc = "Quit window" })

	-- Refresh
	vim.keymap.set("n", "R", function()
		M.refresh_images(buf)
	end, { buffer = buf, desc = "Refresh images" })
end

-- Refresh images in buffer
function M.refresh_images(buf)
	if not M._current_windows then
		vim.notify("No active windows to refresh", vim.log.levels.WARN)
		return
	end

	local ui = require("docker.ui")

	api.list_images(function(err, images)
		if err then
			vim.schedule(function()
				vim.notify("Failed to refresh images: " .. err, vim.log.levels.ERROR)
			end)
			return
		end

		ui.render_images(M._current_windows, images)
	end)
end

-- Close current floating windows
function M.close_current_windows()
	vim.schedule(function()
		if M._current_windows then
			if vim.api.nvim_win_is_valid(M._current_windows.header_win) then
				vim.api.nvim_win_close(M._current_windows.header_win, false)
			end
			if vim.api.nvim_win_is_valid(M._current_windows.main_win) then
				vim.api.nvim_win_close(M._current_windows.main_win, false)
			end
			if vim.api.nvim_win_is_valid(M._current_windows.footer_win) then
				vim.api.nvim_win_close(M._current_windows.footer_win, false)
			end
			M._current_windows = nil
		end

		-- Clear current data
		M._current_data.containers = nil
		M._current_data.images = nil
		M._current_data.window_type = nil

		-- Clean up autocmd if no windows are open
		if M._resize_autocmd_id then
			vim.api.nvim_del_autocmd(M._resize_autocmd_id)
			M._resize_autocmd_id = nil
		end
	end)
end

-- Auto-resize floating windows when terminal is resized
function M.auto_resize_windows()
	if not M._current_windows or not M._current_data.window_type then
		return
	end

	vim.schedule(function()
		-- Check if all windows are still valid
		if
			not vim.api.nvim_win_is_valid(M._current_windows.header_win)
			or not vim.api.nvim_win_is_valid(M._current_windows.main_win)
			or not vim.api.nvim_win_is_valid(M._current_windows.footer_win)
		then
			-- Windows are no longer valid, cleanup
			M._current_windows = nil
			M._current_data.window_type = nil
			return
		end

		local formatter = require("docker.formatter")

		-- Calculate new dimensions based on current terminal size and content
		local content_width
		local item_count = 0
		if M._current_data.window_type == "containers" and M._current_data.containers then
			content_width = formatter.calculate_containers_width(M._current_data.containers)
			item_count = #M._current_data.containers
		elseif M._current_data.window_type == "images" and M._current_data.images then
			content_width = formatter.calculate_images_width(M._current_data.images)
			item_count = #M._current_data.images
		else
			-- Fallback to default width
			content_width = math.floor(vim.o.columns * 0.8)
		end

		-- Calculate dimensions based on content and terminal size
		local max_items_displayable = math.floor(vim.o.lines * 0.6) - 4 -- Reserve space for header/footer and some padding
		local actual_content_rows = math.min(item_count, math.max(10, max_items_displayable)) -- At least 10 rows, but adapt to content and terminal size
		local header_height = 2
		local footer_height = 2
		local content_height = actual_content_rows + 2

		local max_width = math.floor(vim.o.columns * 0.8)
		local total_width = content_width and math.min(content_width, max_width) or max_width
		local start_col = math.floor((vim.o.columns - total_width) / 2)

		local total_height = header_height + content_height + footer_height
		local start_row = math.floor((vim.o.lines - total_height) / 2)

		-- Update window configurations
		vim.api.nvim_win_set_config(M._current_windows.header_win, {
			relative = "editor",
			width = total_width,
			height = header_height,
			col = start_col,
			row = start_row,
		})

		vim.api.nvim_win_set_config(M._current_windows.main_win, {
			relative = "editor",
			width = total_width,
			height = content_height,
			col = start_col,
			row = start_row + header_height,
		})

		vim.api.nvim_win_set_config(M._current_windows.footer_win, {
			relative = "editor",
			width = total_width,
			height = footer_height,
			col = start_col,
			row = start_row + header_height + content_height,
		})
	end)
end

-- Set current windows for actions
function M.set_current_windows(windows)
	M._current_windows = windows

	-- Setup auto-resize if not already done
	if not M._resize_autocmd_id then
		M._resize_autocmd_id = vim.api.nvim_create_autocmd("VimResized", {
			callback = function()
				M.auto_resize_windows()
			end,
			desc = "Auto-resize docker.nvim floating windows",
		})
	end
end

return M
