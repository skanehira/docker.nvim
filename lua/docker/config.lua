-- Configuration management
local M = {}

-- Default configuration
M.defaults = {
  -- Window settings
  window = {
    width = 0.8,
    height = 0.8,
    border = 'rounded',
  },
  
  -- Docker settings
  docker = {
    socket_path = '/var/run/docker.sock',
    timeout = 5000, -- milliseconds
  },
  
  -- Keymaps
  keymaps = {
    containers = {
      start = 'u',
      stop = 'd', 
      restart = 'r',
      remove = 'x',
      logs = 'l',
      exec = 'e',
      quit = 'q',
    },
    images = {
      run = '<CR>',
      remove = 'x',
      pull = 'p',
      inspect = 'i',
      quit = 'q',
    }
  }
}

-- Current configuration
M.config = {}

-- Setup configuration
function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.defaults, opts or {})
end

-- Get configuration value
function M.get(key)
  return M.config[key] or M.defaults[key]
end

return M
