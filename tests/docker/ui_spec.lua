-- Tests for UI module
local helper = require('tests.test_helper')

helper.describe('docker.ui', {
  ['should have show_containers function'] = function()
    local ui = require('docker.ui')
    helper.assert_not_nil(ui.show_containers)
    helper.assert_equal(type(ui.show_containers), 'function')
  end,
  
  ['should have show_images function'] = function()
    local ui = require('docker.ui')
    helper.assert_not_nil(ui.show_images)
    helper.assert_equal(type(ui.show_images), 'function')
  end,
  
  ['should have render_containers function'] = function()
    local ui = require('docker.ui')
    helper.assert_not_nil(ui.render_containers)
    helper.assert_equal(type(ui.render_containers), 'function')
  end,
  
  ['should render containers to buffer correctly'] = function()
    local ui = require('docker.ui')
    local formatter = require('docker.formatter')
    
    local containers = helper.mock_containers
    local lines = formatter.format_containers_table(containers)
    
    helper.assert_not_nil(lines)
    helper.assert_true(#lines > 0)
    
    -- Check running indicator exists
    local indicator_found = false
    for _, line in ipairs(lines) do
      if string.find(line, '●') then
        indicator_found = true
        break
      end
    end
    helper.assert_true(indicator_found)
  end
})