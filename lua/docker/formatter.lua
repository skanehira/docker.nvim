-- Docker data formatting utilities
local M = {}

-- Format container ID (first 12 characters)
function M.format_container_id(id)
  return id:sub(1, 12)
end

-- Format container name (remove leading slash)
function M.format_container_name(name)
  if name:sub(1, 1) == '/' then
    return name:sub(2)
  end
  return name
end

-- Format image name (truncate if too long)
function M.format_image_name(image)
  if #image > 20 then
    return image:sub(1, 20) .. '...'
  end
  return image
end

-- Format port information
function M.format_port(port)
  if port.PublicPort then
    return string.format('%s:%d->%d/%s',
      port.IP or '0.0.0.0',
      port.PublicPort,
      port.PrivatePort,
      port.Type
    )
  else
    return string.format('%d/%s', port.PrivatePort, port.Type)
  end
end

-- Format created date
function M.format_created_date(timestamp)
  local date = os.date('%Y/%m/%d %H:%M:%S', timestamp)
  return date
end

-- Format created date in short format (like "2d", "1h", "5m")
function M.format_created_short(timestamp)
  local now = os.time()
  local diff = now - timestamp

  if diff < 60 then
    return string.format('%ds', diff)
  elseif diff < 3600 then
    return string.format('%dm', math.floor(diff / 60))
  elseif diff < 86400 then
    return string.format('%dh', math.floor(diff / 3600))
  else
    return string.format('%dd', math.floor(diff / 86400))
  end
end

-- Format multiple ports
function M.format_ports(ports)
  if not ports or #ports == 0 then
    return ''
  end

  local formatted_ports = {}
  for _, port in ipairs(ports) do
    table.insert(formatted_ports, M.format_port(port))
  end

  return table.concat(formatted_ports, ', ')
end

-- Check if container is running
local function is_container_running(status)
  return string.find(status:lower(), 'up') ~= nil
end

-- Format container header for display
function M.format_containers_header()
  local lines = {}

  -- Header with new column layout (including space for indicator)
  local header = string.format('  %-12s %-38s %-25s %-20s %-15s %s',
    'ID', 'NAME', 'IMAGE', 'STATUS', 'CREATED', 'PORTS'
  )
  table.insert(lines, header)

  return lines
end

-- Format container table for display (content only)
function M.format_containers_table(containers)
  local lines = {}

  -- Data rows with new column layout
  for _, container in ipairs(containers) do
    local running_indicator = is_container_running(container.Status) and '●' or ' '
    local id = M.format_container_id(container.Id)
    local name = M.format_container_name(container.Names[1])
    local image = container.Image
    local status = container.Status
    local created_short = M.format_created_short(container.Created)
    local ports = M.format_ports(container.Ports)
    
    -- Truncate long values to fit columns
    name = name:sub(1, 38)  -- Reduced to make room for indicator
    image = image:sub(1, 25)
    status = status:sub(1, 20)
    ports = ports ~= '' and ports:sub(1, 15) or '-'

    -- Format: "● abc123456789 nginx-container             nginx:latest             Up 2 hours           2h              8080->80/tcp"
    local line = string.format('%s %-12s %-38s %-25s %-20s %-15s %s',
      running_indicator,
      id,
      name,
      image,
      status,
      created_short,
      ports
    )
    table.insert(lines, line)
  end

  return lines
end

-- Format image header for display
function M.format_images_header()
  local lines = {}

  -- Header
  local header = string.format('%-20s %-12s %-19s %s',
    'REPOSITORY', 'TAG', 'CREATED', 'SIZE'
  )
  table.insert(lines, header)

  -- Separator
  table.insert(lines, string.rep('-', 80))

  return lines
end

-- Format image table for display (content only)
function M.format_images_table(images)
  local lines = {}

  -- Data rows
  for _, image in ipairs(images) do
    local repo_tag = image.RepoTags and image.RepoTags[1] or '<none>:<none>'
    local parts = vim.split(repo_tag, ':')
    local repository = parts[1] or '<none>'
    local tag = parts[2] or '<none>'
    local created = M.format_created_date(image.Created)
    local size = M.format_size(image.Size)

    local line = string.format('%-20s %-12s %-19s %s',
      repository, tag, created, size
    )
    table.insert(lines, line)
  end

  return lines
end

-- Format file size in human readable format
function M.format_size(bytes)
  local units = { 'B', 'KB', 'MB', 'GB', 'TB' }
  local size = bytes
  local unit_index = 1

  while size >= 1024 and unit_index < #units do
    size = size / 1024
    unit_index = unit_index + 1
  end

  return string.format('%.1f%s', size, units[unit_index])
end

return M

