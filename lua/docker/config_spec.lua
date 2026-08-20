local config = require("docker.config")
local notify = require("docker.notify")

describe("docker.config", function()
  local original_notify
  local warnings

  before_each(function()
    config._reset()
    warnings = {}
    original_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      table.insert(warnings, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.notify = original_notify
    config._reset()
    notify.set_debug(false)
  end)

  describe("default values", function()
    it("defines every default keymap of the container list", function()
      -- Spot checks would not notice a binding disappearing, so the whole table is compared.
      config.setup()

      assert.are.same({
        start = "u",
        stop = "d",
        restart = "r",
        kill = "<C-k>",
        pause = "p",
        unpause = "P",
        shell = "a",
        exec = "e",
        logs = "t",
        delete = "D",
        copy_to = "ct",
        copy_from = "cf",
        edit_file = "E",
        open_browser = "<C-o>",
        drilldown = "gd",
      }, config.get().keymaps.container_list)
    end)

    it("defines the default keymaps of the image, volume and network lists", function()
      config.setup()

      local keymaps = config.get().keymaps
      assert.are.same({ quickrun = "r", delete = "D", drilldown = "gd" }, keymaps.image_list)
      assert.are.same({ delete = "D" }, keymaps.volume_list)
      assert.are.same({ delete = "D" }, keymaps.network_list)
    end)

    it("defines the keys common to every view", function()
      config.setup()

      local common = config.get().keymaps.common
      assert.are.same({
        inspect = "<CR>",
        refresh = "R",
        switch_view = "<Tab>",
        help = "?",
        close = "q",
        filter = "<C-f>",
      }, common)
    end)

    it("binds the same key to a different action per view type", function()
      -- BR-015: `r` is restart in the container list and quickrun in the image list.
      config.setup()

      local keymaps = config.get().keymaps
      assert.are.equal("r", keymaps.container_list.restart)
      assert.are.equal("r", keymaps.image_list.quickrun)
    end)

    it("gives the compose service list both per-service and per-project keys", function()
      config.setup()

      assert.are.same({
        up = "u",
        stop = "d",
        restart = "r",
        logs = "t",
        project_up = "U",
        project_down = "D",
        drilldown = "gd",
      }, config.get().keymaps.service_list)
    end)

    it("leaves debug output disabled by default", function()
      config.setup()

      assert.is_false(config.get().debug)
    end)

    it("limits the image column of the container list by default", function()
      config.setup()

      assert.are.same({ image = 30 }, config.get().column_max_widths.container_list)
    end)
  end)

  describe("merging the user's settings", function()
    it("replaces only the keys that were specified", function()
      config.setup({ keymaps = { container_list = { start = "s" } } })

      local container_list = config.get().keymaps.container_list
      assert.are.equal("s", container_list.start)
      assert.are.equal("d", container_list.stop, "keys that were not specified stay at their defaults")
    end)

    it("leaves the other views at their defaults when only some views are specified", function()
      config.setup({ keymaps = { container_list = { start = "s" } } })

      assert.are.equal("r", config.get().keymaps.image_list.quickrun)
    end)

    it("disables a binding when false is specified as its key", function()
      config.setup({ keymaps = { container_list = { delete = false } } })

      assert.is_nil(config.get().keymaps.container_list.delete)
    end)

    it("can enable debug output", function()
      config.setup({ debug = true })

      assert.is_true(config.get().debug)
    end)

    it("propagates enabling debug output to the notify module as well", function()
      config.setup({ debug = true })

      assert.is_true(notify.is_debug())
    end)

    it("replaces a column width limit that was specified", function()
      config.setup({ column_max_widths = { container_list = { image = 50 } } })

      assert.are.equal(50, config.get().column_max_widths.container_list.image)
    end)

    it("removes the limit when false is specified as the width", function()
      config.setup({ column_max_widths = { container_list = { image = false } } })

      assert.is_nil(config.get().column_max_widths.container_list.image)
    end)

    it("leaves the keymaps at their defaults when only the column widths are specified", function()
      config.setup({ column_max_widths = { container_list = { image = 50 } } })

      assert.are.equal("u", config.get().keymaps.container_list.start)
    end)
  end)

  describe("invalid settings", function()
    it("ignores an unknown view type and warns about it", function()
      config.setup({ keymaps = { nonexistent_view = { start = "s" } } })

      assert.is_nil(config.get().keymaps.nonexistent_view)
      assert.are.equal(1, #warnings)
      assert.is_truthy(warnings[1].msg:find("nonexistent_view", 1, true))
      assert.are.equal(vim.log.levels.WARN, warnings[1].level)
    end)

    it("ignores an unknown action name and warns about it", function()
      config.setup({ keymaps = { container_list = { fly_to_the_moon = "x" } } })

      assert.is_nil(config.get().keymaps.container_list.fly_to_the_moon)
      assert.are.equal(1, #warnings)
      assert.is_truthy(warnings[1].msg:find("fly_to_the_moon", 1, true))
    end)

    it("keeps only the valid settings and warns once per invalid entry", function()
      config.setup({
        keymaps = {
          container_list = { start = "s", fly_to_the_moon = "x" },
          nonexistent_view = { start = "y" },
        },
      })

      assert.are.equal("s", config.get().keymaps.container_list.start)
      assert.are.equal(2, #warnings)
    end)

    it("does not warn when every setting is valid", function()
      config.setup({ keymaps = { container_list = { start = "s" } }, debug = true })

      assert.are.same({}, warnings)
    end)

    it("ignores an unknown view type in the column widths and warns about it", function()
      config.setup({ column_max_widths = { nonexistent_view = { image = 20 } } })

      assert.is_nil(config.get().column_max_widths.nonexistent_view)
      assert.are.equal(1, #warnings)
      assert.is_truthy(warnings[1].msg:find("nonexistent_view", 1, true))
      assert.are.equal(vim.log.levels.WARN, warnings[1].level)
    end)

    it("ignores an unknown column name and warns about it", function()
      config.setup({ column_max_widths = { container_list = { ports = 20 } } })

      assert.is_nil(config.get().column_max_widths.container_list.ports)
      assert.are.equal(1, #warnings)
      assert.is_truthy(warnings[1].msg:find("ports", 1, true))
    end)

    it("keeps the default width and warns when the width is not a positive integer", function()
      config.setup({ column_max_widths = { container_list = { image = 0 } } })

      assert.are.equal(30, config.get().column_max_widths.container_list.image)
      assert.are.equal(1, #warnings)
      assert.is_truthy(warnings[1].msg:find("image", 1, true))
    end)

    it("keeps the default width and warns when the width is not a number", function()
      config.setup({ column_max_widths = { container_list = { image = "wide" } } })

      assert.are.equal(30, config.get().column_max_widths.container_list.image)
      assert.are.equal(1, #warnings)
    end)

    it("keeps the defaults and warns when a view is not given a table of widths", function()
      -- Forgetting one level of nesting is the typical mistake, and it has to be told apart
      -- from a setting that simply had no effect.
      config.setup({ column_max_widths = { container_list = 30 } })

      assert.are.equal(30, config.get().column_max_widths.container_list.image)
      assert.are.equal(1, #warnings)
      assert.is_truthy(warnings[1].msg:find("container_list", 1, true))
    end)

    it("keeps the defaults and warns when the column widths are not given as a table", function()
      config.setup({ column_max_widths = 30 })

      assert.are.equal(30, config.get().column_max_widths.container_list.image)
      assert.are.equal(1, #warnings)
      assert.is_truthy(warnings[1].msg:find("column_max_widths", 1, true))
    end)
  end)

  describe("before setup is called", function()
    it("returns the default values", function()
      assert.are.equal("u", config.get().keymaps.container_list.start)
    end)
  end)
end)
