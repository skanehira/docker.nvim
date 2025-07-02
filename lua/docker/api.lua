-- Docker API client using curl
local M = {}

local config = require('docker.config')

-- Execute Docker API request
function M.request(method, path, callback)
  local socket_path = config.get('docker').socket_path
  local timeout = config.get('docker').timeout

  local cmd = {
    'curl',
    '--silent',
    '--unix-socket', socket_path,
    '--max-time', tostring(timeout / 1000),
    '--request', method or 'GET',
    'http://localhost' .. path
  }

  vim.system(cmd, {
    text = true
  }, function(result)
    if result.code == 0 then
      -- Handle empty responses (common for successful operations like container start/stop)
      local stdout_trimmed = result.stdout and vim.trim(result.stdout) or ''
      if stdout_trimmed == '' then
        callback(nil, nil)
      else
        local ok, data = pcall(vim.json.decode, stdout_trimmed)
        if ok then
          callback(nil, data)
        else
          callback('Failed to parse JSON response: ' .. tostring(stdout_trimmed), nil)
        end
      end
    else
      callback('Docker API request failed: ' .. (result.stderr or 'Unknown error'), nil)
    end
  end)
end

-- List containers
function M.list_containers(callback, all)
  local path = '/containers/json'
  if all then
    path = path .. '?all=true'
  end

  M.request('GET', path, callback)
end

-- Start container
function M.start_container(container_id, callback)
  M.request('POST', '/containers/' .. container_id .. '/start', callback)
end

-- Stop container
function M.stop_container(container_id, callback)
  M.request('POST', '/containers/' .. container_id .. '/stop', callback)
end

-- Restart container
function M.restart_container(container_id, callback)
  M.request('POST', '/containers/' .. container_id .. '/restart', callback)
end

-- Kill container
function M.kill_container(container_id, callback)
  M.request('POST', '/containers/' .. container_id .. '/kill', callback)
end

-- Remove container
function M.remove_container(container_id, callback)
  M.request('DELETE', '/containers/' .. container_id, callback)
end

-- List images
function M.list_images(callback)
  M.request('GET', '/images/json', callback)
end

return M
