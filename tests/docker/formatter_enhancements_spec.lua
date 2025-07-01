-- Tests for formatter enhancements (headers, status indicators, time formatting)
local helper = require('tests.test_helper')

helper.describe('docker.formatter enhancements', {
  ['should format created time in short format'] = function()
    local formatter = require('docker.formatter')
    
    local now = os.time()
    
    -- Test seconds
    local thirty_seconds_ago = now - 30
    local result = formatter.format_created_short(thirty_seconds_ago)
    helper.assert_equal(result, '30s')
    
    -- Test minutes
    local five_minutes_ago = now - (5 * 60)
    local result2 = formatter.format_created_short(five_minutes_ago)
    helper.assert_equal(result2, '5m')
    
    -- Test hours
    local two_hours_ago = now - (2 * 3600)
    local result3 = formatter.format_created_short(two_hours_ago)
    helper.assert_equal(result3, '2h')
    
    -- Test days
    local three_days_ago = now - (3 * 86400)
    local result4 = formatter.format_created_short(three_days_ago)
    helper.assert_equal(result4, '3d')
  end,
  
  ['should detect running containers correctly'] = function()
    local formatter = require('docker.formatter')
    
    local running_container = {
      Id = 'abc123456789def',
      Names = {'/nginx-app'},
      Image = 'nginx:latest',
      Status = 'Up 2 hours',
      Created = os.time() - 7200,
      Ports = {}
    }
    
    local stopped_container = {
      Id = 'def456789012abc',
      Names = {'/postgres-db'},
      Image = 'postgres:14',
      Status = 'Exited (0) 1 hour ago',
      Created = os.time() - 3600,
      Ports = {}
    }
    
    local result = formatter.format_containers_table({running_container, stopped_container})
    
    -- Check that running container has indicator
    local has_running_indicator = false
    local has_stopped_space = false
    
    for _, line in ipairs(result) do
      if string.find(line, '●') and string.find(line, 'nginx') then
        has_running_indicator = true
      end
      if string.find(line, '^  postgres') then -- Starts with space (not ●)
        has_stopped_space = true
      end
    end
    
    helper.assert_true(has_running_indicator)
    helper.assert_true(has_stopped_space)
  end,
  
  ['should include proper headers'] = function()
    local formatter = require('docker.formatter')
    
    local containers = helper.mock_containers
    local result = formatter.format_containers_table(containers)
    
    -- Should have header line
    helper.assert_true(#result >= 2) -- At least header + separator
    
    -- Check header content
    local header_line = result[1]
    helper.assert_true(string.find(header_line, 'NAME') ~= nil)
    helper.assert_true(string.find(header_line, 'TAG') ~= nil)
    helper.assert_true(string.find(header_line, 'ID') ~= nil)
    helper.assert_true(string.find(header_line, 'PORTS') ~= nil)
    helper.assert_true(string.find(header_line, 'AGE') ~= nil)
    
    -- Check separator line
    local separator_line = result[2]
    helper.assert_true(string.find(separator_line, '─') ~= nil)
  end,
  
  ['should format image tags correctly'] = function()
    local formatter = require('docker.formatter')
    
    local container_with_tag = {
      Id = 'abc123456789def',
      Names = {'/test-app'},
      Image = 'nginx:1.21-alpine',
      Status = 'Up 1 hour',
      Created = os.time() - 3600,
      Ports = {}
    }
    
    local container_without_tag = {
      Id = 'def456789012abc',
      Names = {'/test-db'},
      Image = 'postgres',
      Status = 'Up 30 minutes',
      Created = os.time() - 1800,
      Ports = {}
    }
    
    local result = formatter.format_containers_table({container_with_tag, container_without_tag})
    
    -- Find the nginx line and check tag
    local nginx_line = nil
    local postgres_line = nil
    
    for _, line in ipairs(result) do
      if string.find(line, 'test%-app') then
        nginx_line = line
      elseif string.find(line, 'test%-db') then
        postgres_line = line
      end
    end
    
    helper.assert_not_nil(nginx_line)
    helper.assert_not_nil(postgres_line)
    
    -- Nginx should have the tag "1.21-alpine" (or truncated version)
    helper.assert_true(string.find(nginx_line, '1%.21') ~= nil or string.find(nginx_line, 'alpine') ~= nil)
    
    -- Postgres should default to "latest"
    helper.assert_true(string.find(postgres_line, 'latest') ~= nil)
  end,
  
  ['should truncate long names and tags'] = function()
    local formatter = require('docker.formatter')
    
    local container_with_long_name = {
      Id = 'abc123456789def',
      Names = {'/very-very-long-container-name-that-exceeds-limit'},
      Image = 'nginx:very-long-tag-name-that-should-be-truncated',
      Status = 'Up 1 hour',
      Created = os.time() - 3600,
      Ports = {}
    }
    
    local result = formatter.format_containers_table({container_with_long_name})
    
    -- Find the container line
    local container_line = nil
    for _, line in ipairs(result) do
      if string.find(line, 'very%-very%-long') then
        container_line = line
        break
      end
    end
    
    helper.assert_not_nil(container_line)
    
    -- Names and tags should be truncated to fit format
    -- The line should not be excessively long
    helper.assert_true(#container_line < 100) -- Reasonable line length
  end
})