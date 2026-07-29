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

  describe("既定値", function()
    it("コンテナ一覧の既定キーマップが全て定義される", function()
      -- 抜き取り検査だと割り当てが消えても気付けない。全体で比較する。
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
        delete = "<C-d>",
        copy_to = "ct",
        copy_from = "cf",
        edit_file = "E",
        open_browser = "<C-o>",
        drilldown = "gd",
      }, config.get().keymaps.container_list)
    end)

    it("イメージ・ボリューム・ネットワーク一覧の既定キーマップが定義される", function()
      config.setup()

      local keymaps = config.get().keymaps
      assert.are.same({ quickrun = "r", delete = "<C-d>", drilldown = "gd" }, keymaps.image_list)
      assert.are.same({ delete = "<C-d>" }, keymaps.volume_list)
      assert.are.same({ delete = "<C-d>" }, keymaps.network_list)
    end)

    it("全ビュー共通のキーが定義される", function()
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

    it("同じキーをビュー種別ごとに別のアクションへ割り当てる", function()
      -- BR-015: `r` はコンテナ一覧では restart、イメージ一覧では quickrun。
      config.setup()

      local keymaps = config.get().keymaps
      assert.are.equal("r", keymaps.container_list.restart)
      assert.are.equal("r", keymaps.image_list.quickrun)
    end)

    it("composeサービス一覧はサービス単位とプロジェクト単位のキーを持つ", function()
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

    it("デバッグ出力は既定で無効になる", function()
      config.setup()

      assert.is_false(config.get().debug)
    end)
  end)

  describe("利用者設定の合成", function()
    it("指定したキーだけを差し替える", function()
      config.setup({ keymaps = { container_list = { start = "s" } } })

      local container_list = config.get().keymaps.container_list
      assert.are.equal("s", container_list.start)
      assert.are.equal("d", container_list.stop, "指定しなかったキーは既定のまま")
    end)

    it("一部のビューだけ指定しても他のビューは既定のままになる", function()
      config.setup({ keymaps = { container_list = { start = "s" } } })

      assert.are.equal("r", config.get().keymaps.image_list.quickrun)
    end)

    it("キーにfalseを指定するとその割り当てを無効にする", function()
      config.setup({ keymaps = { container_list = { delete = false } } })

      assert.is_nil(config.get().keymaps.container_list.delete)
    end)

    it("デバッグを有効にできる", function()
      config.setup({ debug = true })

      assert.is_true(config.get().debug)
    end)

    it("デバッグを有効にすると通知モジュールにも反映される", function()
      config.setup({ debug = true })

      assert.is_true(notify.is_debug())
    end)
  end)

  describe("不正な設定", function()
    it("未知のビュー種別は無視して警告する", function()
      config.setup({ keymaps = { nonexistent_view = { start = "s" } } })

      assert.is_nil(config.get().keymaps.nonexistent_view)
      assert.are.equal(1, #warnings)
      assert.is_truthy(warnings[1].msg:find("nonexistent_view", 1, true))
      assert.are.equal(vim.log.levels.WARN, warnings[1].level)
    end)

    it("未知のアクション名は無視して警告する", function()
      config.setup({ keymaps = { container_list = { fly_to_the_moon = "x" } } })

      assert.is_nil(config.get().keymaps.container_list.fly_to_the_moon)
      assert.are.equal(1, #warnings)
      assert.is_truthy(warnings[1].msg:find("fly_to_the_moon", 1, true))
    end)

    it("正しい設定だけを残して警告は不正な分だけ出す", function()
      config.setup({
        keymaps = {
          container_list = { start = "s", fly_to_the_moon = "x" },
          nonexistent_view = { start = "y" },
        },
      })

      assert.are.equal("s", config.get().keymaps.container_list.start)
      assert.are.equal(2, #warnings)
    end)

    it("正しい設定だけなら警告しない", function()
      config.setup({ keymaps = { container_list = { start = "s" } }, debug = true })

      assert.are.same({}, warnings)
    end)
  end)

  describe("setupを呼ぶ前", function()
    it("既定値を返す", function()
      assert.are.equal("u", config.get().keymaps.container_list.start)
    end)
  end)
end)
