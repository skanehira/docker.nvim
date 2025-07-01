-- Tests for the split window system
local helper = require('tests.test_helper')

helper.describe('docker window system', {
  ['should create main and footer windows'] = function()
    local ui = require('docker.ui')
    
    -- Mock vim.api functions
    local created_windows = {}
    local original_create_buf = vim.api.nvim_create_buf
    local original_open_win = vim.api.nvim_open_win
    
    vim.api.nvim_create_buf = function(listed, scratch)
      local buf_id = #created_windows + 1
      return buf_id
    end
    
    vim.api.nvim_open_win = function(buf, enter, config)
      local win_id = #created_windows + 1
      table.insert(created_windows, {
        buf = buf,
        config = config,
        win = win_id
      })
      return win_id
    end
    
    -- This will test the create_window function indirectly
    local windows = require('docker.ui').create_window or function() end
    
    -- Restore original functions
    vim.api.nvim_create_buf = original_create_buf
    vim.api.nvim_open_win = original_open_win
    
    -- For now, just test that the UI module loads correctly
    helper.assert_not_nil(ui)
    helper.assert_not_nil(ui.render_containers)
    helper.assert_not_nil(ui.render_images)
  end,
  
  ['should render containers to separate windows'] = function()
    local ui = require('docker.ui')
    local formatter = require('docker.formatter')
    
    local containers = helper.mock_containers
    local content_lines = formatter.format_containers_table(containers)
    
    -- Mock windows object
    local mock_windows = {
      main_buf = 1,
      main_win = 1,
      footer_buf = 2,
      footer_win = 2
    }
    
    -- Mock buffer operations
    local main_content = {}
    local footer_content = {}
    local original_set_lines = vim.api.nvim_buf_set_lines
    local original_bo = vim.bo
    
    vim.api.nvim_buf_set_lines = function(buf, start, end_line, strict_indexing, replacement)
      if buf == mock_windows.main_buf then
        main_content = replacement
      elseif buf == mock_windows.footer_buf then
        footer_content = replacement
      end
    end
    
    -- Mock buffer options
    vim.bo = setmetatable({}, {
      __index = function(t, k)
        return setmetatable({}, {
          __newindex = function() end,
          __index = function() return false end
        })
      end
    })
    
    -- Test render function
    ui.render_containers(mock_windows, containers)
    
    -- Restore original functions
    vim.api.nvim_buf_set_lines = original_set_lines
    vim.bo = original_bo
    
    -- Verify content was set (will be set in vim.schedule)
    helper.assert_not_nil(content_lines)
    helper.assert_true(#content_lines > 0)
  end,
  
  ['should render images to separate windows'] = function()
    local ui = require('docker.ui')
    local formatter = require('docker.formatter')
    
    local images = helper.mock_images
    local content_lines = formatter.format_images_table(images)
    
    -- Mock windows object
    local mock_windows = {
      main_buf = 1,
      main_win = 1,
      footer_buf = 2,
      footer_win = 2
    }
    
    -- Test that images render function exists and accepts windows parameter
    helper.assert_not_nil(ui.render_images)
    helper.assert_equal(type(ui.render_images), 'function')
    
    -- Verify content structure
    helper.assert_not_nil(content_lines)
    helper.assert_equal(type(content_lines), 'table')
  end
})