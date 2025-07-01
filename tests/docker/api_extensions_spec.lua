-- Tests for new API functions (restart, remove)
local helper = require('tests.test_helper')

helper.describe('docker.api extensions', {
  ['should have restart_container function'] = function()
    local api = require('docker.api')
    helper.assert_not_nil(api.restart_container)
    helper.assert_equal(type(api.restart_container), 'function')
  end,
  
  ['should have remove_container function'] = function()
    local api = require('docker.api')
    helper.assert_not_nil(api.remove_container)
    helper.assert_equal(type(api.remove_container), 'function')
  end,
  
  ['should call correct API endpoints'] = function()
    local api = require('docker.api')
    
    -- Mock the request function to capture calls
    local request_calls = {}
    local original_request = api.request
    api.request = function(method, path, callback)
      table.insert(request_calls, {
        method = method,
        path = path
      })
      -- Call callback with empty success response
      callback(nil, {})
    end
    
    -- Test restart container
    api.restart_container('test123', function() end)
    helper.assert_equal(#request_calls, 1)
    helper.assert_equal(request_calls[1].method, 'POST')
    helper.assert_equal(request_calls[1].path, '/containers/test123/restart')
    
    -- Test remove container
    api.remove_container('test456', function() end)
    helper.assert_equal(#request_calls, 2)
    helper.assert_equal(request_calls[2].method, 'DELETE')
    helper.assert_equal(request_calls[2].path, '/containers/test456')
    
    -- Restore original function
    api.request = original_request
  end,
  
  ['should handle API errors correctly'] = function()
    local api = require('docker.api')
    
    -- Mock the request function to simulate error
    local original_request = api.request
    api.request = function(method, path, callback)
      callback('API Error: Container not found', nil)
    end
    
    -- Test error handling
    local error_received = nil
    local data_received = nil
    
    api.restart_container('nonexistent', function(err, data)
      error_received = err
      data_received = data
    end)
    
    helper.assert_not_nil(error_received)
    helper.assert_nil(data_received)
    helper.assert_true(string.find(error_received, 'Container not found') ~= nil)
    
    -- Restore original function
    api.request = original_request
  end
})