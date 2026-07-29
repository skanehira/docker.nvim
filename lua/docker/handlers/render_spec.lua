local render = require("docker.handlers.render")

describe("docker.handlers.render", function()
  local scheduled

  --- 偽の時計。実時間を待たずにデバウンスの挙動を検査する。
  local function fake_timers()
    scheduled = {}
    render._set_timer_factory(function(delay, callback)
      local entry = { delay = delay, callback = callback, stopped = false }
      table.insert(scheduled, entry)
      return {
        stop = function()
          entry.stopped = true
        end,
      }
    end)
  end

  --- 直近に仕掛けられた、まだ止められていないタイマーを発火させる。
  local function fire_pending()
    for _, entry in ipairs(scheduled) do
      if not entry.stopped then
        entry.callback()
        entry.stopped = true
      end
    end
  end

  before_each(function()
    render._reset()
    fake_timers()
  end)

  after_each(function()
    render._set_timer_factory(nil)
    render._reset()
  end)

  describe("request", function()
    it("要求してすぐには描画しない", function()
      local drawn = 0

      render.request("container", function()
        drawn = drawn + 1
      end)

      assert.are.equal(0, drawn)
    end)

    it("待ち時間が過ぎると描画する", function()
      local drawn = 0
      render.request("container", function()
        drawn = drawn + 1
      end)

      fire_pending()

      assert.are.equal(1, drawn)
    end)

    it("連続する要求は1回にまとめられる", function()
      -- docker events にはデーモン全体のイベントが流れるため、
      -- まとめないと一斉変更のたびに描画が空回りする。
      local drawn = 0
      local function draw()
        drawn = drawn + 1
      end

      render.request("container", draw)
      render.request("container", draw)
      render.request("container", draw)
      fire_pending()

      assert.are.equal(1, drawn)
    end)

    it("まとめられた要求では最後に渡した描画が実行される", function()
      local order = {}

      render.request("container", function()
        table.insert(order, "first")
      end)
      render.request("container", function()
        table.insert(order, "last")
      end)
      fire_pending()

      assert.are.same({ "last" }, order)
    end)

    it("キーが違う要求はまとめない", function()
      local drawn = {}

      render.request("container", function()
        table.insert(drawn, "container")
      end)
      render.request("image", function()
        table.insert(drawn, "image")
      end)
      fire_pending()

      assert.are.equal(2, #drawn)
    end)

    it("描画した後の要求は改めてまとめ直す", function()
      local drawn = 0
      local function draw()
        drawn = drawn + 1
      end

      render.request("container", draw)
      fire_pending()
      render.request("container", draw)
      fire_pending()

      assert.are.equal(2, drawn)
    end)
  end)

  describe("待ち時間", function()
    it("イベント受信から1秒以内に描画要求が出る幅になっている", function()
      -- G9: 別プロセスの操作が 1 秒以内に一覧へ反映される。
      -- 内訳は「デバウンス + 対象の再取得 (実測 20〜60ms) + 描画 (実測 2ms)」。
      render.request("container", function() end)

      assert.are.equal(render.DELAY_MS, scheduled[1].delay)
      assert.is_true(render.DELAY_MS < 1000, "1 秒の目標に対し余裕があること")
      assert.is_true(render.DELAY_MS >= 50, "一斉変更をまとめられる幅があること")
    end)
  end)

  describe("cancel", function()
    it("待機中の描画要求を取り消せる", function()
      local drawn = 0
      render.request("container", function()
        drawn = drawn + 1
      end)

      render.cancel("container")
      fire_pending()

      assert.are.equal(0, drawn)
    end)

    it("取り消した後も新しい要求は受け付ける", function()
      local drawn = 0
      local function draw()
        drawn = drawn + 1
      end
      render.request("container", draw)
      render.cancel("container")

      render.request("container", draw)
      fire_pending()

      assert.are.equal(1, drawn)
    end)
  end)
end)
