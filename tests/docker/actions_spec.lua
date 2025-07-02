-- Tests for docker actions
local helper = require('tests.test_helper')

helper.describe('docker.actions', {
  ['should have container actions'] = function()
    local actions = require('docker.actions')
    helper.assert_not_nil(actions.start_container)
    helper.assert_not_nil(actions.stop_container)
    helper.assert_equal(type(actions.start_container), 'function')
    helper.assert_equal(type(actions.stop_container), 'function')
  end,
  
  ['should have get_current_container function'] = function()
    local actions = require('docker.actions')
    helper.assert_not_nil(actions.get_current_container)
    helper.assert_equal(type(actions.get_current_container), 'function')
  end,
  
  ['should parse container from current line'] = function()
    local actions = require('docker.actions')
    
    -- Mock container line (new format with indicator: ● ID NAME IMAGE STATUS CREATED PORTS)
    local container_line = '● abc123456789 nginx-container           nginx:latest             Up 2 hours           2h              8080->80/tcp'
    
    local container_id = actions.parse_container_id_from_line(container_line)
    helper.assert_equal(container_id, 'abc123456789')
  end,
  
  ['should return nil for invalid container line'] = function()
    local actions = require('docker.actions')
    
    -- Test header line  
    local header_line = '  ID           NAME                                     IMAGE                   STATUS                   CREATED             PORTS'
    local container_id = actions.parse_container_id_from_line(header_line)
    helper.assert_nil(container_id)
    
    -- Test separator line
    local separator_line = '────────────────────────────────────────────────────'
    local container_id2 = actions.parse_container_id_from_line(separator_line)
    helper.assert_nil(container_id2)
  end,
  
  ['should setup buffer keymaps'] = function()
    local actions = require('docker.actions')
    helper.assert_not_nil(actions.setup_container_keymaps)
    helper.assert_equal(type(actions.setup_container_keymaps), 'function')
  end
})