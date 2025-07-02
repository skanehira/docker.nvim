-- Docker data formatting utilities
local M = {}

-- Format container ID (first 12 characters)
function M.format_container_id(id)
	return id:sub(1, 12)
end

-- Format container name (remove leading slash)
function M.format_container_name(name)
	if name:sub(1, 1) == "/" then
		return name:sub(2)
	end
	return name
end

-- Format image name (truncate if too long)
function M.format_image_name(image)
	if #image > 20 then
		return image:sub(1, 20) .. "..."
	end
	return image
end

-- Format port information
function M.format_port(port)
	if port.PublicPort then
		return string.format("%s:%d->%d/%s", port.IP or "0.0.0.0", port.PublicPort, port.PrivatePort, port.Type)
	else
		return string.format("%d/%s", port.PrivatePort, port.Type)
	end
end

-- Format created date
function M.format_created_date(timestamp)
	local date = os.date("%Y/%m/%d %H:%M:%S", timestamp)
	return date
end

-- Format created date in short format (like "2d", "1h", "5m")
function M.format_created_short(timestamp)
	local now = os.time()
	local diff = now - timestamp

	if diff < 60 then
		return string.format("%ds", diff)
	elseif diff < 3600 then
		return string.format("%dm", math.floor(diff / 60))
	elseif diff < 86400 then
		return string.format("%dh", math.floor(diff / 3600))
	else
		return string.format("%dd", math.floor(diff / 86400))
	end
end

-- Format multiple ports
function M.format_ports(ports)
	if not ports or #ports == 0 then
		return ""
	end

	local formatted_ports = {}
	for _, port in ipairs(ports) do
		table.insert(formatted_ports, M.format_port(port))
	end

	return table.concat(formatted_ports, ", ")
end

-- Check if container is running
local function is_container_running(status)
	return string.find(status:lower(), "up") ~= nil
end

-- Format container header for display
function M.format_containers_header(max_image_width, max_status_width)
	local lines = {}

	-- Use dynamic widths for IMAGE and STATUS columns
	max_image_width = max_image_width or 30
	max_status_width = max_status_width or 25

	-- Build format string with dynamic widths
	local format_str = string.format("  %%-12s %%-38s %%-%ds %%-%ds %%-15s %%s", max_image_width, max_status_width)
	local header = string.format(format_str, "ID", "NAME", "IMAGE", "STATUS", "CREATED", "PORTS")
	table.insert(lines, header)

	return lines
end

-- Format container table for display (content only)
function M.format_containers_table(containers, max_image_width, max_status_width)
	local lines = {}

	-- Use provided widths or defaults
	max_image_width = max_image_width or 30
	max_status_width = max_status_width or 25

	-- Data rows with new column layout
	for _, container in ipairs(containers) do
		local running_indicator = is_container_running(container.Status) and "●" or " "
		local id = M.format_container_id(container.Id)
		local name = M.format_container_name(container.Names[1])
		local image = container.Image
		local status = container.Status
		local created_short = M.format_created_short(container.Created)
		local ports = M.format_ports(container.Ports)

		-- Only truncate ID and NAME columns as requested
		name = name:sub(1, 38) -- Reduced to make room for indicator
		-- IMAGE, STATUS, and PORTS should display fully without truncation

		-- Build format string with dynamic widths
		local format_str =
			string.format("%%s %%-12s %%-38s %%-%ds %%-%ds %%-15s %%s", max_image_width, max_status_width)
		local line = string.format(
			format_str,
			running_indicator,
			id,
			name,
			image,
			status,
			created_short,
			ports ~= "" and ports or "-"
		)
		table.insert(lines, line)
	end

	return lines
end

-- Calculate optimal width for containers table
function M.calculate_containers_width(containers)
	-- Base width for fixed columns: indicator(1) + space(1) + ID(12) + space(1) + NAME(38) + space(1) + CREATED(15) + space(1) = 70
	-- Plus 2 spaces for IMAGE and STATUS columns = 72
	local base_width = 72
	local max_image_width = 5 -- Minimum width for "IMAGE" header
	local max_status_width = 6 -- Minimum width for "STATUS" header
	local max_ports_width = 5 -- Minimum width for "PORTS" header

	-- Find the longest strings for each dynamic column
	for _, container in ipairs(containers or {}) do
		local image = container.Image
		local status = container.Status
		local ports = M.format_ports(container.Ports)
		local ports_display = ports ~= "" and ports or "-"

		max_image_width = math.max(max_image_width, #image)
		max_status_width = math.max(max_status_width, #status)
		max_ports_width = math.max(max_ports_width, #ports_display)
	end

	-- Add dynamic column widths
	local total_width = base_width + max_image_width + max_status_width + max_ports_width

	-- Store the calculated widths for later use (backward compatibility)
	M._max_image_width = max_image_width
	M._max_status_width = max_status_width

	-- Ensure minimum width for readability
	local final_width = math.max(total_width, 140)

	-- Return width and layout information
	return final_width,
		{
			max_image_width = max_image_width,
			max_status_width = max_status_width,
			max_ports_width = max_ports_width,
		}
end

-- Format image header for display
function M.format_images_header()
	local lines = {}

	-- Header
	local header = string.format("%-20s %-12s %-19s %s", "REPOSITORY", "TAG", "CREATED", "SIZE")
	table.insert(lines, header)

	-- Separator
	table.insert(lines, string.rep("-", 80))

	return lines
end

-- Format image table for display (content only)
function M.format_images_table(images)
	local lines = {}

	-- Data rows
	for _, image in ipairs(images) do
		local repo_tag = image.RepoTags and image.RepoTags[1] or "<none>:<none>"
		local parts = vim.split(repo_tag, ":")
		local repository = parts[1] or "<none>"
		local tag = parts[2] or "<none>"
		local created = M.format_created_date(image.Created)
		local size = M.format_size(image.Size)

		local line = string.format("%-20s %-12s %-19s %s", repository, tag, created, size)
		table.insert(lines, line)
	end

	return lines
end

-- Calculate optimal width for images table
function M.calculate_images_width(images)
	-- Base width for images: REPOSITORY(20) + TAG(12) + CREATED(19) + SIZE = 51 + separators
	local base_width = 60
	local max_size_width = 0

	-- Find the longest SIZE string
	for _, image in ipairs(images or {}) do
		local size = M.format_size(image.Size)
		max_size_width = math.max(max_size_width, #size)
	end

	-- Add padding
	local total_width = base_width + max_size_width + 2

	-- Ensure minimum width for readability
	local final_width = math.max(total_width, 80)

	-- Return width and layout information
	return final_width, {
		max_size_width = max_size_width,
	}
end

-- Format file size in human readable format
function M.format_size(bytes)
	local units = { "B", "KB", "MB", "GB", "TB" }
	local size = bytes
	local unit_index = 1

	while size >= 1024 and unit_index < #units do
		size = size / 1024
		unit_index = unit_index + 1
	end

	return string.format("%.1f%s", size, units[unit_index])
end

return M
