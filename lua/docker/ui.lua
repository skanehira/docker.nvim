-- UI management for floating windows
local M = {}

local api = require("docker.api")
local config = require("docker.config")
local formatter = require("docker.formatter")

-- Helper function to set buffer options
local function setup_buffer_options(buf, options)
	vim.bo[buf].modifiable = options.modifiable ~= false -- default true
	vim.bo[buf].buftype = options.buftype or "nofile"
	vim.bo[buf].swapfile = false
	vim.bo[buf].bufhidden = options.bufhidden or "wipe"
	if options.filetype then
		vim.bo[buf].filetype = options.filetype
	end
end

-- Helper function to update buffer content
local function update_buffer_content(buf, lines, start_line, end_line)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, start_line or 0, end_line or -1, false, lines)
	vim.bo[buf].modifiable = false
end

-- Create floating windows with separate header, content, and footer
local function create_windows(title, item_count, content_width)
	-- Calculate optimal dimensions based on content and terminal size
	local max_items_displayable = math.floor(vim.o.lines * 0.6) - 4 -- Reserve space for header/footer and some padding
	local actual_content_rows = item_count and math.min(item_count, math.max(10, max_items_displayable)) or 10
	local header_height = 2 -- Header + separator (no extra padding)
	local footer_height = 2 -- Footer content (minimal height)
	local content_height = actual_content_rows + 2 -- Content + small padding

	-- Use content-based width, but limit to 80% of terminal width
	local max_width = math.floor(vim.o.columns * 0.8)
	local total_width = content_width and math.min(content_width, max_width) or max_width
	local start_col = math.floor((vim.o.columns - total_width) / 2)

	-- Calculate vertical positioning (center all windows as a group with minimal gaps)
	local total_height = header_height + content_height + footer_height
	local start_row = math.floor((vim.o.lines - total_height) / 2)

	-- Format title with item count
	local window_title = item_count and string.format(" %s [%d items] ", title, item_count)
		or string.format(" %s ", title)

	-- Create header window (with top and side borders, bottom separator)
	local header_buf = vim.api.nvim_create_buf(false, true)
	local header_win = vim.api.nvim_open_win(header_buf, false, {
		relative = "editor",
		width = total_width,
		height = header_height,
		col = start_col,
		row = start_row,
		style = "minimal",
		border = { "┌", "─", "┐", "│", "│", " ", "│", "│" },
		title = window_title,
		title_pos = "center",
	})

	-- Create main content window (with left and right borders only)
	local main_buf = vim.api.nvim_create_buf(false, true)
	local main_win = vim.api.nvim_open_win(main_buf, true, {
		relative = "editor",
		width = total_width,
		height = content_height,
		col = start_col,
		row = start_row + header_height,
		style = "minimal",
		border = { "├", "─", "┤", "│", "┤", "─", "├", "│" },
		footer = " Commands ",
		footer_pos = "center",
	})

	-- Create footer window (with top separator and bottom borders)
	local footer_buf = vim.api.nvim_create_buf(false, true)
	local footer_win = vim.api.nvim_open_win(footer_buf, false, {
		relative = "editor",
		width = total_width,
		height = footer_height,
		col = start_col,
		row = start_row + header_height + content_height,
		style = "minimal",
		border = { "├", "─", "┤", "│", "┘", "─", "└", "│" },
	})

	-- Set buffer options
	setup_buffer_options(header_buf, { modifiable = false, filetype = "docker-containers" })
	setup_buffer_options(main_buf, { modifiable = false, filetype = "docker-containers" })
	setup_buffer_options(footer_buf, { modifiable = false })

	return {
		header_buf = header_buf,
		header_win = header_win,
		main_buf = main_buf,
		main_win = main_win,
		footer_buf = footer_buf,
		footer_win = footer_win,
	}
end

-- Render containers to windows
function M.render_containers(windows, containers)
	-- Update stored data for auto-resize functionality
	local actions = require("docker.actions")
	if actions._current_data then
		actions._current_data.containers = containers
		actions._current_data.window_type = "containers"
	end

	-- Store container data in the main buffer for easy access by line number
	if windows.main_buf and vim.api.nvim_buf_is_valid(windows.main_buf) then
		-- Store containers data as buffer variable
		vim.b[windows.main_buf].docker_containers = containers or {}
	end

	-- Get the calculated max widths from formatter
	local max_image_width = formatter._max_image_width or 30
	local max_status_width = formatter._max_status_width or 25

	local header_lines = formatter.format_containers_header(max_image_width, max_status_width)
	local content_lines = formatter.format_containers_table(containers, max_image_width, max_status_width)

	-- Generate footer content from configuration
	local keymaps = config.get("keymaps").containers
	local footer_content = string.format(
		"%s:start %s:stop %s:restart %s:kill %s:attach %s:inspect %s:remove R:refresh %s:quit",
		keymaps.start,
		keymaps.stop,
		keymaps.restart,
		keymaps.kill,
		keymaps.attach,
		keymaps.inspect,
		keymaps.remove,
		keymaps.quit
	)

	local footer_lines = {
		"",
		footer_content,
	}

	-- Schedule to avoid fast event context error
	vim.schedule(function()
		-- Validate windows and buffers exist
		if not windows or not windows.header_buf or not windows.main_buf or not windows.footer_buf then
			return
		end

		-- Render header
		if vim.api.nvim_buf_is_valid(windows.header_buf) then
			update_buffer_content(windows.header_buf, header_lines)
		end

		-- Render main content
		if vim.api.nvim_buf_is_valid(windows.main_buf) then
			update_buffer_content(windows.main_buf, content_lines)
		end

		-- Render footer
		if vim.api.nvim_buf_is_valid(windows.footer_buf) then
			update_buffer_content(windows.footer_buf, footer_lines)
		end
	end)
end

-- Render images to windows
function M.render_images(windows, images)
	-- Update stored data for auto-resize functionality
	local actions = require("docker.actions")
	if actions._current_data then
		actions._current_data.images = images
		actions._current_data.window_type = "images"
	end

	-- Store image data in the main buffer for easy access by line number
	if windows.main_buf and vim.api.nvim_buf_is_valid(windows.main_buf) then
		-- Store images data as buffer variable
		vim.b[windows.main_buf].docker_images = images or {}
	end

	local header_lines = formatter.format_images_header()
	local content_lines = formatter.format_images_table(images)

	-- Generate footer content from configuration
	local keymaps = config.get("keymaps").images
	local footer_content = string.format(
		"%s:run %s:remove %s:pull %s:inspect R:refresh %s:quit",
		keymaps.run,
		keymaps.remove,
		keymaps.pull,
		keymaps.inspect,
		keymaps.quit
	)

	local footer_lines = {
		"",
		footer_content,
	}

	-- Schedule to avoid fast event context error
	vim.schedule(function()
		-- Validate windows and buffers exist
		if not windows or not windows.header_buf or not windows.main_buf or not windows.footer_buf then
			return
		end

		-- Render header
		if vim.api.nvim_buf_is_valid(windows.header_buf) then
			update_buffer_content(windows.header_buf, header_lines)
		end

		-- Render main content
		if vim.api.nvim_buf_is_valid(windows.main_buf) then
			update_buffer_content(windows.main_buf, content_lines)
		end

		-- Render footer
		if vim.api.nvim_buf_is_valid(windows.footer_buf) then
			update_buffer_content(windows.footer_buf, footer_lines)
		end
	end)
end

-- Show containers window
function M.show_containers()
	-- Load containers data first to calculate optimal width
	api.list_containers(function(err, containers)
		vim.schedule(function()
			if err then
				-- Show error with default width
				local windows = create_windows("Docker Containers")
				local actions = require("docker.actions")
				actions.set_current_windows(windows)
				actions.setup_container_keymaps(windows.main_buf)

				update_buffer_content(windows.main_buf, { "Error: " .. err })
				return
			end

			-- Calculate optimal width based on content
			local content_width = formatter.calculate_containers_width(containers)
			local windows = create_windows("Docker Containers", #containers, content_width)

			-- Setup keymaps on main buffer
			local actions = require("docker.actions")
			actions.set_current_windows(windows)
			actions.setup_container_keymaps(windows.main_buf)

			-- Store data for auto-resize functionality
			actions._current_data.containers = containers
			actions._current_data.window_type = "containers"

			-- Render containers immediately
			M.render_containers(windows, containers)
		end)
	end, true) -- Show all containers
end

-- Show images window
function M.show_images()
	-- Load images data first to calculate optimal width
	api.list_images(function(err, images)
		vim.schedule(function()
			if err then
				-- Show error with default width
				local windows = create_windows("Docker Images")
				local actions = require("docker.actions")
				actions.set_current_windows(windows)
				actions.setup_image_keymaps(windows.main_buf)

				update_buffer_content(windows.main_buf, { "Error: " .. err })
				return
			end

			-- Calculate optimal width based on content
			local content_width = formatter.calculate_images_width(images)
			local windows = create_windows("Docker Images", #images, content_width)

			-- Setup keymaps on main buffer
			local actions = require("docker.actions")
			actions.set_current_windows(windows)
			actions.setup_image_keymaps(windows.main_buf)

			-- Store data for auto-resize functionality
			actions._current_data.images = images
			actions._current_data.window_type = "images"

			-- Render images immediately
			M.render_images(windows, images)
		end)
	end)
end

return M
