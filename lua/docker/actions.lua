-- Docker container/image actions
local M = {}

local api = require("docker.api")
local config = require("docker.config")

-- Get container data from current cursor position using buffer-stored data
function M.get_current_container_data()
	local buf = vim.api.nvim_get_current_buf()
	local containers = vim.b[buf].docker_containers

	if not containers or #containers == 0 then
		return nil
	end

	-- Get current cursor line (1-indexed)
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

	-- In the new UI design, the main window contains only container data
	-- No header in main window, so line 1 = container index 1, line 2 = container index 2, etc.
	local data_index = cursor_line

	-- Validate index bounds (Lua arrays are 1-indexed)
	if data_index < 1 or data_index > #containers then
		return nil
	end

	return containers[data_index]
end

-- Get container ID from current cursor position (backward compatibility)
function M.get_current_container()
	local container_data = M.get_current_container_data()
	return container_data and container_data.Id:sub(1, 12) or nil
end

-- Get image data from current cursor position using buffer-stored data
function M.get_current_image_data()
	local buf = vim.api.nvim_get_current_buf()
	local images = vim.b[buf].docker_images

	if not images or #images == 0 then
		return nil
	end

	-- Get current cursor line (1-indexed)
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

	-- In the new UI design, the main window contains only image data
	-- No header in main window, so line 1 = image index 1, line 2 = image index 2, etc.
	local data_index = cursor_line

	-- Validate index bounds (Lua arrays are 1-indexed)
	if data_index < 1 or data_index > #images then
		return nil
	end

	return images[data_index]
end

-- DEPRECATED: Parse container ID from table line (kept for backward compatibility)
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

-- Helper function to create container actions with common pattern
local function create_container_action(action_name, api_func, success_message_format)
	return function(buf)
		local container_data = M.get_current_container_data()
		if not container_data then
			vim.notify("No container selected", vim.log.levels.WARN)
			return
		end

		local container_id = container_data.Id:sub(1, 12)
		local container_name = container_data.Names[1]:sub(2) -- Remove leading "/"

		vim.notify(
			action_name .. " container " .. container_name .. " (" .. container_id .. ")...",
			vim.log.levels.INFO
		)

		api_func(container_id, function(err, data)
			vim.schedule(function()
				if err then
					vim.notify(
						"Failed to " .. action_name:lower() .. " container: " .. tostring(err),
						vim.log.levels.ERROR
					)
					return
				end

				local message = success_message_format and string.format(success_message_format, container_name)
					or ("Container " .. container_name .. " " .. action_name:lower() .. "ed successfully")
				vim.notify(message, vim.log.levels.INFO)
			end)

			-- Refresh container list
			M.refresh_containers(buf)
		end)
	end
end

-- Start container action
M.start_container = create_container_action("Starting", api.start_container, "Container %s started successfully")

-- Stop container action
M.stop_container = create_container_action("Stopping", api.stop_container, "Container %s stopped successfully")

-- Restart container action
M.restart_container =
	create_container_action("Restarting", api.restart_container, "Container %s restarted successfully")

-- Kill container action
M.kill_container = create_container_action("Killing", api.kill_container, "Container %s killed successfully")

-- Attach to container action
function M.attach_container(buf)
	local container_data = M.get_current_container_data()
	if not container_data then
		vim.notify("No container selected", vim.log.levels.WARN)
		return
	end

	local container_id = container_data.Id:sub(1, 12)

	-- Check if container is running using the stored data
	if not string.find(container_data.Status:lower(), "up") then
		vim.notify("Container is not running. Start it first.", vim.log.levels.WARN)
		return
	end

	vim.notify(
		"Attaching to container " .. container_data.Names[1]:sub(2) .. " (" .. container_id .. ")...",
		vim.log.levels.INFO
	)

	-- Close current floating windows before opening terminal
	M.close_current_windows()

	api.attach_container(container_id, function(err)
		if err then
			vim.schedule(function()
				vim.notify("Failed to attach to container: " .. err, vim.log.levels.ERROR)
			end)
		end
	end)
end

-- Function to display the formatted content
local function display_content(inspect_buf, container_id, lines)
	-- Set the buffer content
	vim.api.nvim_buf_set_lines(inspect_buf, 0, -1, false, lines)
	vim.bo[inspect_buf].modifiable = false

	-- Close container list and open the buffer in a new window
	M.close_current_windows()
	vim.cmd("rightbelow vsplit")
	vim.api.nvim_win_set_buf(0, inspect_buf)

	-- Set window title
	vim.api.nvim_buf_set_name(inspect_buf, "Container Inspect: " .. tostring(container_id))

	vim.notify("Container inspection opened in new window", vim.log.levels.INFO)
	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(0, true)
	end, { buffer = inspect_buf, desc = "Close container inspect window" })
end

-- Inspect container action
function M.inspect_container(buf)
	local container_data = M.get_current_container_data()
	if not container_data then
		vim.notify("No container selected", vim.log.levels.WARN)
		return
	end

	local container_id = container_data.Id:sub(1, 12)
	local container_name = container_data.Names[1]:sub(2) -- Remove leading "/"

	vim.notify("Inspecting container " .. container_name .. " (" .. container_id .. ")...", vim.log.levels.INFO)

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
			vim.bo[inspect_buf].modifiable = true

			local json_string = vim.json.encode(data)
			local jq_available = vim.fn.executable("jq") == 1

			if jq_available then
				vim.system({ "jq", "." }, {
					stdin = json_string,
					text = true,
				}, function(result)
					vim.schedule(function()
						if result.code == 0 and result.stdout then
							local formatted_lines = vim.split(vim.trim(result.stdout), "\n")
							display_content(inspect_buf, container_id, formatted_lines)
						else
							-- Fallback to basic formatting if jq fails
							display_content(inspect_buf, container_id, { json_string })
						end
					end)
				end)
			else
				display_content(inspect_buf, container_id, { json_string })
			end
		end)
	end)
end

-- Remove container action
M.remove_container = create_container_action("Removing", api.remove_container, "Container %s removed successfully")

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
	local api = require("docker.api")
	local formatter = require("docker.formatter")
	local ui = require("docker.ui")

	ui.refresh_window_content({
		type = "containers",
		data_key = "containers",
		api_call = api.list_containers,
		api_args = true, -- show all containers
		calculate_width = formatter.calculate_containers_width,
		render_function = ui.render_containers,
		fallback_function = ui.show_containers,
	})
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
		M.refresh_images()
	end, { buffer = buf, desc = "Refresh images" })
end

-- Refresh images in buffer
function M.refresh_images()
	local api = require("docker.api")
	local formatter = require("docker.formatter")
	local ui = require("docker.ui")

	ui.refresh_window_content({
		type = "images",
		data_key = "images",
		api_call = api.list_images,
		api_args = nil, -- no additional args for list_images
		calculate_width = formatter.calculate_images_width,
		render_function = ui.render_images,
		fallback_function = ui.show_images,
	})
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
