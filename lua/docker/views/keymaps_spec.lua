local config = require("docker.config")
local keymaps = require("docker.views.keymaps")

describe("docker.views.keymaps", function()
  before_each(function()
    config._reset()
  end)

  after_each(function()
    config._reset()
  end)

  describe("resolve", function()
    it("returns the common keys and the view-specific keys together", function()
      local resolved = keymaps.resolve("container_list")

      assert.are.equal("inspect", resolved["<CR>"])
      assert.are.equal("start", resolved["u"])
    end)

    it("binds s to stop and l/h to expanding and collapsing a project", function()
      local resolved = keymaps.resolve("container_list")

      assert.are.equal("stop", resolved["s"])
      assert.are.equal("expand_group", resolved["l"])
      assert.are.equal("collapse_group", resolved["h"])
      assert.is_nil(resolved["d"], "d is no longer the stop key")
    end)

    it("reflects keys the user has changed for the group folding", function()
      config.setup({ keymaps = { container_list = { expand_group = "L", collapse_group = "H" } } })

      local resolved = keymaps.resolve("container_list")
      assert.are.equal("expand_group", resolved["L"])
      assert.are.equal("collapse_group", resolved["H"])
    end)

    it("does not resolve an action the view does not have", function()
      -- The container list has no quickrun (it is an action of the image list).
      local resolved = keymaps.resolve("container_list")

      for _, action in pairs(resolved) do
        assert.is_true(action ~= "quickrun", "container_list must not have quickrun")
      end
    end)

    it("resolves the same key to a different action per view type", function()
      -- BR-015
      assert.are.equal("restart", keymaps.resolve("container_list")["r"])
      assert.are.equal("quickrun", keymaps.resolve("image_list")["r"])
    end)

    it("prefers the view-specific key when it collides with a common key", function()
      config.setup({ keymaps = { container_list = { start = "R" } } })

      -- The common refresh is also bound to "R", but the view-specific start wins.
      assert.are.equal("start", keymaps.resolve("container_list")["R"])
    end)

    it("reflects a key the user has changed", function()
      config.setup({ keymaps = { container_list = { start = "n" } } })

      local resolved = keymaps.resolve("container_list")
      assert.are.equal("start", resolved["n"])
      assert.is_nil(resolved["u"])
      assert.are.equal("stop", resolved["s"])
    end)

    it("does not resolve an action that has been disabled", function()
      config.setup({ keymaps = { container_list = { delete = false } } })

      assert.is_nil(keymaps.resolve("container_list")["D"])
    end)

    it("returns only the common keys for an unknown view type", function()
      local resolved = keymaps.resolve("nonexistent_view")

      assert.are.equal("inspect", resolved["<CR>"])
      assert.is_nil(resolved["u"])
      assert.is_nil(resolved["s"])
    end)
  end)

  describe("describe_view", function()
    it("returns the pairs of key and action that are active in the view", function()
      local rows = keymaps.describe_view("image_list")

      local actions = {}
      for _, row in ipairs(rows) do
        actions[row.action] = row.key
      end
      assert.are.equal("r", actions.quickrun)
      assert.are.equal("D", actions.delete)
      assert.are.equal("<CR>", actions.inspect)
    end)

    it("does not include actions that are inactive in that view", function()
      local rows = keymaps.describe_view("image_list")

      for _, row in ipairs(rows) do
        assert.is_true(row.action ~= "start", "image_list must not have start")
      end
    end)

    it("orders the rows by key in ascending order", function()
      -- If the order wobbled for the same content, the row order of the help would change between runs.
      local rows = keymaps.describe_view("volume_list")

      local keys = {}
      for _, row in ipairs(rows) do
        table.insert(keys, row.key)
      end
      local sorted = vim.deepcopy(keys)
      table.sort(sorted)
      assert.are.same(sorted, keys)
      assert.is_true(#keys > 1)
    end)
  end)
end)
