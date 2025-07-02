-- Tests for docker.config module
local helper = require('tests.test_helper')

helper.describe('docker.config', {
  ['should have default configuration'] = function()
    local config = require('docker.config')
    helper.assert_not_nil(config.defaults)
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
    
    local docker_config = config.get('docker')
    helper.assert_equal(docker_config.timeout, 60000)
    helper.assert_equal(docker_config.socket_path, '/var/run/docker.sock')
  end,
  
  ['should merge user configuration'] = function()
    local config = require('docker.config')
    config.setup({
      docker = {
        timeout = 30000
      }
    })
    
    local docker_config = config.get('docker')
    helper.assert_equal(docker_config.timeout, 30000)
    helper.assert_equal(docker_config.socket_path, '/var/run/docker.sock') -- default
  end
})