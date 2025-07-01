-- Tests for docker.config module
local helper = require('tests.test_helper')

helper.describe('docker.config', {
  ['should have default configuration'] = function()
    local config = require('docker.config')
    helper.assert_not_nil(config.defaults)
    helper.assert_not_nil(config.defaults.window)
    helper.assert_not_nil(config.defaults.docker)
    helper.assert_not_nil(config.defaults.keymaps)
  end,
  
  ['should have setup function'] = function()
    local config = require('docker.config')
    helper.assert_not_nil(config.setup)
    helper.assert_equal(type(config.setup), 'function')
  end,
  
  ['should have get function'] = function()
    local config = require('docker.config')
    helper.assert_not_nil(config.get)
    helper.assert_equal(type(config.get), 'function')
  end,
  
  ['should return default values'] = function()
    local config = require('docker.config')
    config.setup({}) -- Reset to defaults
    
    local window_config = config.get('window')
    helper.assert_equal(window_config.width, 0.8)
    helper.assert_equal(window_config.height, 0.8)
    helper.assert_equal(window_config.border, 'rounded')
  end,
  
  ['should merge user configuration'] = function()
    local config = require('docker.config')
    config.setup({
      window = {
        width = 0.9,
        border = 'single'
      }
    })
    
    local window_config = config.get('window')
    helper.assert_equal(window_config.width, 0.9)
    helper.assert_equal(window_config.height, 0.8) -- default
    helper.assert_equal(window_config.border, 'single')
  end
})