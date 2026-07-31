local config = require("docker.config")
local help = require("docker.views.help")

describe("docker.views.help", function()
  before_each(function()
    config._reset()
  end)

  after_each(function()
    config._reset()
  end)

  describe("build", function()
    it("generates the listing of keys and actions from the keymap definitions", function()
      local lines = help.build("container_list")

      local joined = table.concat(lines, "\n")
      assert.is_truthy(joined:match("u%s+start"), joined)
      assert.is_truthy(joined:match("D%s+delete"), joined)
    end)

    it("does not list actions that are inactive in that view", function()
      local joined = table.concat(help.build("image_list"), "\n")

      assert.is_nil(joined:find(" pause", 1, true), "image_list has no pause: " .. joined)
      assert.is_nil(joined:find(" start", 1, true), "image_list has no start: " .. joined)
    end)

    it("lists the keys common to every view as well", function()
      local joined = table.concat(help.build("volume_list"), "\n")

      assert.is_truthy(joined:find("refresh", 1, true))
      assert.is_truthy(joined:find("close", 1, true))
    end)

    it("reflects a key the user has changed", function()
      config.setup({ keymaps = { container_list = { start = "s" } } })

      local joined = table.concat(help.build("container_list"), "\n")

      assert.is_truthy(joined:match("s%s+start"), joined)
    end)

    it("does not list an action that has been disabled", function()
      config.setup({ keymaps = { container_list = { delete = false } } })

      local joined = table.concat(help.build("container_list"), "\n")

      assert.is_nil(joined:find("delete", 1, true))
    end)

    it("aligns the keys and the actions into columns", function()
      local lines = help.build("volume_list")

      -- The action name starts at the same position on every line.
      local columns = {}
      for _, line in ipairs(lines) do
        local col = line:find("%S%s*$")
        if line:match("%S") then
          table.insert(columns, select(2, line:find("^%s*%S+%s+")))
        end
        local _ = col
      end
      assert.is_true(#columns > 1)
      for _, col in ipairs(columns) do
        assert.are.equal(columns[1], col)
      end
    end)

    it("keeps the row order the same between runs", function()
      assert.are.same(help.build("container_list"), help.build("container_list"))
    end)
  end)

  describe("open", function()
    local window = require("docker.ui.window")
    local handle

    after_each(function()
      if handle then
        window.close(handle)
        handle = nil
      end
    end)

    it("stacks itself in front of the list", function()
      local below = window.open({ title = "Containers", zindex = 50 })

      handle = help.open("container_list")

      local help_z = vim.api.nvim_win_get_config(handle.winid).zindex
      local below_z = vim.api.nvim_win_get_config(below.winid).zindex
      assert.is_true(help_z > below_z, ("help=%d list=%d"):format(help_z, below_z))
      window.close(below)
    end)

    it("puts the listing of keys into the buffer", function()
      handle = help.open("container_list")

      local joined = table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
      assert.is_truthy(joined:find("start", 1, true))
    end)
  end)
end)
