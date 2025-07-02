-- Tests for actions integration with window system
local helper = require('tests.test_helper')

helper.describe('docker.actions integration', {
  ['should have set_current_windows function'] = function()
    local actions = require('docker.actions')
    helper.assert_not_nil(actions.set_current_windows)
    helper.assert_equal(type(actions.set_current_windows), 'function')
  end,

  ['should store and use current windows'] = function()
    local actions = require('docker.actions')

    local mock_windows = {
      main_buf = 1,
      main_win = 1,
      footer_buf = 2,
      footer_win = 2
    }

    -- Set windows
    actions.set_current_windows(mock_windows)

    -- Verify that _current_windows is set
    helper.assert_not_nil(actions._current_windows)
    helper.assert_equal(actions._current_windows.main_buf, mock_windows.main_buf)
    helper.assert_equal(actions._current_windows.footer_buf, mock_windows.footer_buf)
  end,

  ['should handle refresh without windows'] = function()
    local actions = require('docker.actions')

    -- Clear current windows
    actions._current_windows = nil

    -- Mock vim.notify
    local notify_called = false
    local notify_message = nil
    local original_notify = vim.notify
    vim.notify = function(message, level)
      notify_called = true
      notify_message = message
    end

    -- Try to refresh without windows
    actions.refresh_containers(1)

    -- Restore original notify
    vim.notify = original_notify

    -- Verify warning was shown
    helper.assert_true(notify_called)
    helper.assert_true(string.find(notify_message, 'No active windows') ~= nil)
  end,

  ['should have restart, kill and remove container functions'] = function()
    local actions = require('docker.actions')

    helper.assert_not_nil(actions.restart_container)
    helper.assert_equal(type(actions.restart_container), 'function')

    helper.assert_not_nil(actions.kill_container)
    helper.assert_equal(type(actions.kill_container), 'function')

    helper.assert_not_nil(actions.remove_container)
    helper.assert_equal(type(actions.remove_container), 'function')
  end,

  ['should parse container ID from new format lines'] = function()
    local actions = require('docker.actions')

    -- Test with new format: "● abc123456789 nginx-container             nginx:latest             Up 2 hours           2h              8080->80/tcp"
    local container_line =
    '● abc123456789 nginx-container             nginx:latest             Up 2 hours           2h              8080->80/tcp'
    local container_id = actions.parse_container_id_from_line(container_line)
    helper.assert_equal(container_id, 'abc123456789')

    -- Test stopped container
    local container_line2 =
    '  def456789012 postgres-db                 postgres:14              Exited (0) 1 hour ag 1h              -'
    local container_id2 = actions.parse_container_id_from_line(container_line2)
    helper.assert_equal(container_id2, 'def456789012')

    -- Test header line (should return nil)
    local header_line =
    'ID           NAME                                                                                   IMAGE                   STATUS                   CREATED             PORTS'
    local container_id3 = actions.parse_container_id_from_line(header_line)
    helper.assert_nil(container_id3)

    -- Test separator line (should return nil)
    local separator_line = '────────────────────────────────────────────────────'
    local container_id4 = actions.parse_container_id_from_line(separator_line)
    helper.assert_nil(container_id4)
  end
})

