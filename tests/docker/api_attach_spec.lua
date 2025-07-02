-- Tests for docker API attach functionality
local helper = require('tests.test_helper')

helper.describe('docker.api attach functionality', {
  ['should have attach_container function'] = function()
    local api = require('docker.api')
    helper.assert_not_nil(api.attach_container)
    helper.assert_equal(type(api.attach_container), 'function')
  end,
  
  ['should call terminal command for attach'] = function()
    local api = require('docker.api')
    local container_id = 'test123'
    local callback_called = false
    local callback_err = nil
    
    -- Mock vim.cmd and vim.schedule
    local original_cmd = vim.cmd
    local original_schedule = vim.schedule
    local terminal_command = nil
    
    vim.cmd = function(cmd)
      terminal_command = cmd
    end
    
    vim.schedule = function(func)
      func() -- Execute immediately for testing
    end
    
    -- Test attach_container
    api.attach_container(container_id, function(err, data)
      callback_called = true
      callback_err = err
    end)
    
    -- Restore original functions
    vim.cmd = original_cmd
    vim.schedule = original_schedule
    
    helper.assert_true(callback_called)
    helper.assert_nil(callback_err)
    helper.assert_not_nil(terminal_command)
    helper.assert_true(string.find(terminal_command, 'terminal docker attach ' .. container_id) ~= nil)
  end
})