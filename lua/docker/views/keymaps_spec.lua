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
    it("共通のキーとビュー固有のキーを合わせて返す", function()
      local resolved = keymaps.resolve("container_list")

      assert.are.equal("inspect", resolved["<CR>"])
      assert.are.equal("start", resolved["u"])
    end)

    it("ビューに無いアクションは解決されない", function()
      -- コンテナ一覧に quickrun は無い (イメージ一覧のアクション)。
      local resolved = keymaps.resolve("container_list")

      for _, action in pairs(resolved) do
        assert.is_true(action ~= "quickrun", "container_list に quickrun があってはいけない")
      end
    end)

    it("同じキーがビュー種別ごとに別のアクションへ解決される", function()
      -- BR-015
      assert.are.equal("restart", keymaps.resolve("container_list")["r"])
      assert.are.equal("quickrun", keymaps.resolve("image_list")["r"])
    end)

    it("ビュー固有のキーが共通のキーと衝突するときはビュー固有を優先する", function()
      config.setup({ keymaps = { container_list = { start = "R" } } })

      -- 共通の refresh も "R" だが、ビュー固有の start が勝つ。
      assert.are.equal("start", keymaps.resolve("container_list")["R"])
    end)

    it("利用者が変更したキーが反映される", function()
      config.setup({ keymaps = { container_list = { start = "s" } } })

      local resolved = keymaps.resolve("container_list")
      assert.are.equal("start", resolved["s"])
      assert.is_nil(resolved["u"])
    end)

    it("無効にしたアクションは解決されない", function()
      config.setup({ keymaps = { container_list = { delete = false } } })

      assert.is_nil(keymaps.resolve("container_list")["D"])
    end)

    it("未知のビュー種別は共通のキーだけを返す", function()
      local resolved = keymaps.resolve("nonexistent_view")

      assert.are.equal("inspect", resolved["<CR>"])
      assert.is_nil(resolved["u"])
    end)
  end)

  describe("describe_view", function()
    it("ビューで有効なキーとアクションの組を並べて返す", function()
      local rows = keymaps.describe_view("image_list")

      local actions = {}
      for _, row in ipairs(rows) do
        actions[row.action] = row.key
      end
      assert.are.equal("r", actions.quickrun)
      assert.are.equal("D", actions.delete)
      assert.are.equal("<CR>", actions.inspect)
    end)

    it("そのビューで無効な操作は載らない", function()
      local rows = keymaps.describe_view("image_list")

      for _, row in ipairs(rows) do
        assert.is_true(row.action ~= "start", "image_list に start があってはいけない")
      end
    end)

    it("キーの昇順で並ぶ", function()
      -- 同じ内容でも並びが揺れるとヘルプの行順が実行のたびに変わる。
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
