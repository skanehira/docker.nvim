-- Docker container/image actions
local M = {}

local api = require('docker.api')
local config = require('docker.config')

-- Parse container ID from table line
function M.parse_container_id_from_line(line)
  if not line or line == '' then
    return nil
  end

  -- New format: "● nginx-app       latest       abc123456789 -        2h"
  --          or "  postgres        14           def456789012 -        1h"
  -- Handle both running (●) and stopped (space) containers
  local trimmed
  if line:sub(1, 1) == ' ' then
    -- Line starts with spaces (stopped container)
    trimmed = line:sub(3) -- Skip "  "
  else
    -- Line starts with UTF-8 bullet (running container)
    trimmed = line:sub(5) -- Skip "● " (UTF-8 bullet + space)
  end

  local pattern = '^([%w%-_]+) +(%S+) +([a-f0-9]+)'
  local name, tag, container_id = string.match(trimmed, pattern)

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
    vim.notify('No container selected', vim.log.levels.WARN)
    return
  end

  vim.notify('Starting container ' .. container_id .. '...', vim.log.levels.INFO)

  api.start_container(container_id, function(err)
    vim.schedule(function()
      if err then
        vim.notify('Failed to start container: ' .. err, vim.log.levels.ERROR)
        return
      end

      vim.notify('Container ' .. container_id .. ' started successfully', vim.log.levels.INFO)
    end)

    -- Refresh container list
    M.refresh_containers(buf)
  end)
end

-- Stop container action
function M.stop_container(buf)
  local container_id = M.get_current_container()
  if not container_id then
    vim.notify('No container selected', vim.log.levels.WARN)
    return
  end

  vim.notify('Stopping container ' .. container_id .. '...', vim.log.levels.INFO)

  api.stop_container(container_id, function(err)
    vim.schedule(function()
      if err then
        vim.notify('Failed to stop container: ' .. err, vim.log.levels.ERROR)
        return
      end

      vim.notify('Container ' .. container_id .. ' stopped successfully', vim.log.levels.INFO)
    end)

    -- Refresh container list
    M.refresh_containers(buf)
  end)
end

-- Restart container action
function M.restart_container(buf)
  local container_id = M.get_current_container()
  if not container_id then
    vim.notify('No container selected', vim.log.levels.WARN)
    return
  end

  vim.notify('Restarting container ' .. container_id .. '...', vim.log.levels.INFO)

  api.restart_container(container_id, function(err)
    vim.schedule(function()
      if err then
        vim.notify('Failed to restart container: ' .. err, vim.log.levels.ERROR)
        return
      end

      vim.notify('Container ' .. container_id .. ' restarted successfully', vim.log.levels.INFO)
    end)

    -- Refresh container list
    M.refresh_containers(buf)
  end)
end

-- Remove container action
function M.remove_container(buf)
  local container_id = M.get_current_container()
  if not container_id then
    vim.notify('No container selected', vim.log.levels.WARN)
    return
  end

  vim.notify('Removing container ' .. container_id .. '...', vim.log.levels.INFO)

  api.remove_container(container_id, function(err)
    vim.schedule(function()
      if err then
        vim.notify('Failed to remove container: ' .. err, vim.log.levels.ERROR)
        return
      end

      vim.notify('Container ' .. container_id .. ' removed successfully', vim.log.levels.INFO)
    end)

    -- Refresh container list
    M.refresh_containers(buf)
  end)
end

-- Store current windows for refresh operations
M._current_windows = nil

-- Refresh containers in buffer
function M.refresh_containers(buf)
  if not M._current_windows then
    vim.notify('No active windows to refresh', vim.log.levels.WARN)
    return
  end

  local ui = require('docker.ui')

  api.list_containers(function(err, containers)
    if err then
      vim.schedule(function()
        vim.notify('Failed to refresh containers: ' .. err, vim.log.levels.ERROR)
      end)
      return
    end

    ui.render_containers(M._current_windows, containers)
  end, true)
end

-- Setup keymaps for container buffer
function M.setup_container_keymaps(buf)
  local keymaps = config.get('keymaps').containers

  -- Start container
  vim.keymap.set('n', keymaps.start, function()
    M.start_container(buf)
  end, { buffer = buf, desc = 'Start container' })

  -- Stop container
  vim.keymap.set('n', keymaps.stop, function()
    M.stop_container(buf)
  end, { buffer = buf, desc = 'Stop container' })

  -- Restart container
  vim.keymap.set('n', keymaps.restart, function()
    M.restart_container(buf)
  end, { buffer = buf, desc = 'Restart container' })

  -- Remove container
  vim.keymap.set('n', keymaps.remove, function()
    M.remove_container(buf)
  end, { buffer = buf, desc = 'Remove container' })

  -- Quit window
  vim.keymap.set('n', keymaps.quit, function()
    -- Close all windows in the current window set
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
    else
      vim.api.nvim_win_close(0, false)
    end
  end, { buffer = buf, desc = 'Quit window' })

  -- Refresh
  vim.keymap.set('n', 'R', function()
    M.refresh_containers(buf)
  end, { buffer = buf, desc = 'Refresh containers' })
end

-- Setup keymaps for image buffer
function M.setup_image_keymaps(buf)
  local keymaps = config.get('keymaps').images

  -- Quit window
  vim.keymap.set('n', keymaps.quit, function()
    -- Close all windows in the current window set
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
    else
      vim.api.nvim_win_close(0, false)
    end
  end, { buffer = buf, desc = 'Quit window' })

  -- Refresh
  vim.keymap.set('n', 'R', function()
    M.refresh_images(buf)
  end, { buffer = buf, desc = 'Refresh images' })
end

-- Refresh images in buffer
function M.refresh_images(buf)
  if not M._current_windows then
    vim.notify('No active windows to refresh', vim.log.levels.WARN)
    return
  end

  local ui = require('docker.ui')

  api.list_images(function(err, images)
    if err then
      vim.schedule(function()
        vim.notify('Failed to refresh images: ' .. err, vim.log.levels.ERROR)
      end)
      return
    end

    ui.render_images(M._current_windows, images)
  end)
end

-- Set current windows for actions
function M.set_current_windows(windows)
  M._current_windows = windows
end

return M

