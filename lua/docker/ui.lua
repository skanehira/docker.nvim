-- UI management for floating windows
local M = {}

local api = require('docker.api')
local config = require('docker.config')
local formatter = require('docker.formatter')

-- Create floating windows with separate header, content, and footer
local function create_windows(title, item_count)
  local win_config = config.get('window')

  -- Calculate optimal dimensions with proper proportions
  local max_container_rows = 10                 -- Maximum rows for containers
  local header_height = 2                       -- Header + separator (no extra padding)
  local footer_height = 2                       -- Footer content (minimal height)
  local content_height = max_container_rows + 2 -- Content + small padding

  local total_width = math.floor(vim.o.columns * 0.8)
  local start_col = math.floor((vim.o.columns - total_width) / 2)

  -- Calculate vertical positioning (center all windows as a group with minimal gaps)
  local gap = 0 -- No gap between windows for unified appearance
  local total_height = header_height + content_height + footer_height
  local start_row = math.floor((vim.o.lines - total_height) / 2)

  -- Format title with item count
  local window_title = item_count and
      string.format(' %s [%d items] ', title, item_count) or
      string.format(' %s ', title)

  -- Create header window (with top and side borders, bottom separator)
  local header_buf = vim.api.nvim_create_buf(false, true)
  local header_win = vim.api.nvim_open_win(header_buf, false, {
    relative = 'editor',
    width = total_width,
    height = header_height,
    col = start_col,
    row = start_row,
    style = 'minimal',
    border = { '┌', '─', '┐', '│', '│', ' ', '│', '│' },
    title = window_title,
    title_pos = 'center'
  })

  -- Create main content window (with left and right borders only)
  local main_buf = vim.api.nvim_create_buf(false, true)
  local main_win = vim.api.nvim_open_win(main_buf, true, {
    relative = 'editor',
    width = total_width,
    height = content_height,
    col = start_col,
    row = start_row + header_height,
    style = 'minimal',
    border = { '├', '─', '┤', '│', '┤', '─', '├', '│' },
    footer = ' Commands ',
    footer_pos = 'center'

  })

  -- Create footer window (with top separator and bottom borders)
  local footer_buf = vim.api.nvim_create_buf(false, true)
  local footer_win = vim.api.nvim_open_win(footer_buf, false, {
    relative = 'editor',
    width = total_width,
    height = footer_height,
    col = start_col,
    row = start_row + header_height + content_height,
    style = 'minimal',
    border = { '├', '─', '┤', '│', '┘', '─', '└', '│' },
  })

  -- Set buffer options for header window
  vim.bo[header_buf].modifiable = false
  vim.bo[header_buf].buftype = 'nofile'
  vim.bo[header_buf].swapfile = false
  vim.bo[header_buf].bufhidden = 'wipe'

  -- Set buffer options for main window (no readonly to avoid warnings)
  vim.bo[main_buf].modifiable = false
  vim.bo[main_buf].buftype = 'nofile'
  vim.bo[main_buf].swapfile = false
  vim.bo[main_buf].bufhidden = 'wipe'

  -- Set buffer options for footer window
  vim.bo[footer_buf].modifiable = false
  vim.bo[footer_buf].buftype = 'nofile'
  vim.bo[footer_buf].swapfile = false
  vim.bo[footer_buf].bufhidden = 'wipe'

  return {
    header_buf = header_buf,
    header_win = header_win,
    main_buf = main_buf,
    main_win = main_win,
    footer_buf = footer_buf,
    footer_win = footer_win
  }
end

-- Render containers to windows
function M.render_containers(windows, containers)
  local header_lines = formatter.format_containers_header()
  local content_lines = formatter.format_containers_table(containers)

  -- Footer content
  local footer_lines = {
    '',
    'u:start d:stop r:restart x:remove R:refresh q:quit'
  }

  -- Schedule to avoid fast event context error
  vim.schedule(function()
    -- Render header
    vim.bo[windows.header_buf].modifiable = true
    vim.api.nvim_buf_set_lines(windows.header_buf, 0, -1, false, header_lines)
    vim.bo[windows.header_buf].modifiable = false

    -- Render main content
    vim.bo[windows.main_buf].modifiable = true
    vim.api.nvim_buf_set_lines(windows.main_buf, 0, -1, false, content_lines)
    vim.bo[windows.main_buf].modifiable = false

    -- Render footer
    vim.bo[windows.footer_buf].modifiable = true
    vim.api.nvim_buf_set_lines(windows.footer_buf, 0, -1, false, footer_lines)
    vim.bo[windows.footer_buf].modifiable = false
  end)
end

-- Render images to windows
function M.render_images(windows, images)
  local header_lines = formatter.format_images_header()
  local content_lines = formatter.format_images_table(images)

  -- Footer content
  local footer_lines = {
    '',
    'Enter:run x:remove p:pull i:inspect R:refresh q:quit'
  }

  -- Schedule to avoid fast event context error
  vim.schedule(function()
    -- Render header
    vim.bo[windows.header_buf].modifiable = true
    vim.api.nvim_buf_set_lines(windows.header_buf, 0, -1, false, header_lines)
    vim.bo[windows.header_buf].modifiable = false

    -- Render main content
    vim.bo[windows.main_buf].modifiable = true
    vim.api.nvim_buf_set_lines(windows.main_buf, 0, -1, false, content_lines)
    vim.bo[windows.main_buf].modifiable = false

    -- Render footer
    vim.bo[windows.footer_buf].modifiable = true
    vim.api.nvim_buf_set_lines(windows.footer_buf, 0, -1, false, footer_lines)
    vim.bo[windows.footer_buf].modifiable = false
  end)
end

-- Show containers window
function M.show_containers()
  local windows = create_windows('Docker Containers')

  -- Setup keymaps on main buffer
  local actions = require('docker.actions')
  actions.set_current_windows(windows)
  actions.setup_container_keymaps(windows.main_buf)

  -- Set initial content
  vim.bo[windows.main_buf].modifiable = true
  vim.api.nvim_buf_set_lines(windows.main_buf, 0, -1, false, { 'Loading containers...' })
  vim.bo[windows.main_buf].modifiable = false

  -- Load containers data
  api.list_containers(function(err, containers)
    if err then
      vim.schedule(function()
        vim.bo[windows.main_buf].modifiable = true
        vim.api.nvim_buf_set_lines(windows.main_buf, 0, -1, false, { 'Error: ' .. err })
        vim.bo[windows.main_buf].modifiable = false
      end)
      return
    end

    -- Update header window title with item count
    vim.schedule(function()
      local win_title = string.format(' Docker Containers [%d items] ', #containers)
      vim.api.nvim_win_set_config(windows.header_win, { title = win_title })
    end)

    M.render_containers(windows, containers)
  end, true) -- Show all containers
end

-- Show images window
function M.show_images()
  local windows = create_windows('Docker Images')

  -- Setup keymaps on main buffer
  local actions = require('docker.actions')
  actions.set_current_windows(windows)
  actions.setup_image_keymaps(windows.main_buf)

  -- Set initial content
  vim.bo[windows.main_buf].modifiable = true
  vim.api.nvim_buf_set_lines(windows.main_buf, 0, -1, false, { 'Loading images...' })
  vim.bo[windows.main_buf].modifiable = false

  -- Load images data
  api.list_images(function(err, images)
    if err then
      vim.schedule(function()
        vim.bo[windows.main_buf].modifiable = true
        vim.api.nvim_buf_set_lines(windows.main_buf, 0, -1, false, { 'Error: ' .. err })
        vim.bo[windows.main_buf].modifiable = false
      end)
      return
    end

    -- Update header window title with item count
    vim.schedule(function()
      local win_title = string.format(' Docker Images [%d items] ', #images)
      vim.api.nvim_win_set_config(windows.header_win, { title = win_title })
    end)

    M.render_images(windows, images)
  end)
end

return M

