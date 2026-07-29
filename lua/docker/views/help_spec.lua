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
    it("キーマップ定義からキーと操作の一覧を生成する", function()
      local lines = help.build("container_list")

      local joined = table.concat(lines, "\n")
      assert.is_truthy(joined:match("u%s+start"), joined)
      assert.is_truthy(joined:match("D%s+delete"), joined)
    end)

    it("そのビューで無効な操作は載らない", function()
      local joined = table.concat(help.build("image_list"), "\n")

      assert.is_nil(joined:find("quickrun は", 1, true))
      assert.is_nil(joined:find(" start", 1, true), "image_list に start は無い: " .. joined)
    end)

    it("全ビュー共通のキーも載る", function()
      local joined = table.concat(help.build("volume_list"), "\n")

      assert.is_truthy(joined:find("refresh", 1, true))
      assert.is_truthy(joined:find("close", 1, true))
    end)

    it("利用者が変更したキーが反映される", function()
      config.setup({ keymaps = { container_list = { start = "s" } } })

      local joined = table.concat(help.build("container_list"), "\n")

      assert.is_truthy(joined:match("s%s+start"), joined)
    end)

    it("無効にしたアクションは載らない", function()
      config.setup({ keymaps = { container_list = { delete = false } } })

      local joined = table.concat(help.build("container_list"), "\n")

      assert.is_nil(joined:find("delete", 1, true))
    end)

    it("キーと操作が桁揃えされる", function()
      local lines = help.build("volume_list")

      -- どの行も同じ桁から操作名が始まる。
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

    it("行の並びは実行のたびに変わらない", function()
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

    it("一覧より前面に重ねて表示する", function()
      local below = window.open({ title = "Containers", zindex = 50 })

      handle = help.open("container_list")

      local help_z = vim.api.nvim_win_get_config(handle.winid).zindex
      local below_z = vim.api.nvim_win_get_config(below.winid).zindex
      assert.is_true(help_z > below_z, ("help=%d list=%d"):format(help_z, below_z))
      window.close(below)
    end)

    it("キーの一覧がバッファに入る", function()
      handle = help.open("container_list")

      local joined = table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
      assert.is_truthy(joined:find("start", 1, true))
    end)
  end)
end)
