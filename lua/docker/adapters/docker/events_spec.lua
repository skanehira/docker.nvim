local events = require("docker.adapters.docker.events")

--- docker events が 1 行として出す JSON。
---@param overrides table|nil
---@return string
local function raw_line(overrides)
  return vim.json.encode(vim.tbl_deep_extend("force", {
    status = "start",
    id = "abc123",
    Type = "container",
    Action = "start",
    Actor = { ID = "abc123", Attributes = { name = "web" } },
    scope = "local",
    time = 1785000000,
    timeNano = 1785000000123456789,
  }, overrides or {}))
end

describe("docker.adapters.docker.events", function()
  describe("decoder", function()
    it("1チャンクに完全な1行が届くとイベントを1件返す", function()
      local decoder = events.new_decoder()

      local got = decoder:push(raw_line() .. "\n")

      assert.are.equal(1, #got)
      assert.are.equal("container", got[1].type)
      assert.are.equal("start", got[1].action)
    end)

    it("行の途中で分割されたチャンク列から完全なイベントを組み立てる", function()
      local line = raw_line() .. "\n"
      local decoder = events.new_decoder()

      local first = decoder:push(line:sub(1, 20))
      local second = decoder:push(line:sub(21, 45))
      local third = decoder:push(line:sub(46))

      assert.are.same({}, first)
      assert.are.same({}, second)
      assert.are.equal(1, #third)
      assert.are.equal("abc123", third[1].id)
    end)

    it("複数行が1チャンクで届くと全件返す", function()
      local decoder = events.new_decoder()

      local got = decoder:push(raw_line({ id = "a", Actor = { ID = "a" } }) .. "\n" .. raw_line({
        id = "b",
        Actor = { ID = "b" },
      }) .. "\n")

      assert.are.equal(2, #got)
      assert.are.equal("a", got[1].id)
      assert.are.equal("b", got[2].id)
    end)

    it("改行が来るまではイベントを返さない", function()
      local decoder = events.new_decoder()

      assert.are.same({}, decoder:push(raw_line()))
    end)

    it("巨大な1行でも組み立てられる", function()
      local big = raw_line({ Actor = { ID = "abc123", Attributes = { blob = string.rep("x", 100000) } } })
      local decoder = events.new_decoder()

      local got = {}
      local pos = 1
      while pos <= #big do
        vim.list_extend(got, decoder:push(big:sub(pos, pos + 4095)))
        pos = pos + 4096
      end
      vim.list_extend(got, decoder:push("\n"))

      assert.are.equal(1, #got)
      assert.are.equal("abc123", got[1].id)
    end)

    it("空行は読み飛ばす", function()
      local decoder = events.new_decoder()

      local got = decoder:push("\n\n" .. raw_line() .. "\n\n")

      assert.are.equal(1, #got)
    end)

    it("解析できない行は読み飛ばして後続を処理する", function()
      local decoder = events.new_decoder()

      local got = decoder:push("not json\n" .. raw_line() .. "\n")

      assert.are.equal(1, #got)
    end)
  end)

  describe("イベントの取り出し", function()
    it("時刻は秒精度のtimeを使いtimeNanoは持ち込まない", function()
      -- timeNano は vim.json.decode で浮動小数点化され下位桁が落ちるため、
      -- 再購読の起点には使わない。イベント全体を比較して混入していないことを示す。
      local decoder = events.new_decoder()

      local got = decoder:push(raw_line({ time = 1785000000 }) .. "\n")

      assert.are.same({
        type = "container",
        action = "start",
        id = "abc123",
        time = 1785000000,
      }, got[1])
    end)

    it("コンテナのIDはActorのIDから取る", function()
      local decoder = events.new_decoder()

      local got = decoder:push(raw_line({ Actor = { ID = "container-id" } }) .. "\n")

      assert.are.equal("container-id", got[1].id)
    end)

    it("ボリュームの名前はActorのIDから取る", function()
      -- ボリュームのイベントでは名前が Actor.Attributes.name ではなく Actor.ID に入る。
      local decoder = events.new_decoder()

      local got = decoder:push(raw_line({
        Type = "volume",
        Action = "create",
        Actor = { ID = "my-volume", Attributes = { driver = "local" } },
      }) .. "\n")

      assert.are.equal("volume", got[1].type)
      assert.are.equal("my-volume", got[1].id)
    end)

    it("Actorが無いイベントは読み飛ばす", function()
      local decoder = events.new_decoder()

      local got = decoder:push(vim.json.encode({ Type = "container", Action = "start", time = 1 }) .. "\n")

      assert.are.same({}, got)
    end)
  end)

  describe("subscribe", function()
    local started

    before_each(function()
      started = {}
      events._set_starter(function(cmd, handlers)
        table.insert(started, { cmd = cmd, handlers = handlers })
        return 900 + #started
      end)
    end)

    after_each(function()
      events._set_starter(nil)
    end)

    it("docker events をJSON形式で購読する", function()
      events.subscribe({ on_event = function() end })

      assert.are.same({ "docker", "events", "--format", "{{json .}}" }, started[1].cmd)
    end)

    it("sinceを指定すると再開位置を渡す", function()
      events.subscribe({ since = "1785000000", on_event = function() end })

      assert.are.same({ "docker", "events", "--format", "{{json .}}", "--since", "1785000000" }, started[1].cmd)
    end)

    it("受信したイベントを通知する", function()
      local received = {}
      events.subscribe({
        on_event = function(ev)
          table.insert(received, ev)
        end,
      })

      started[1].handlers.on_stdout(raw_line() .. "\n")

      assert.are.equal(1, #received)
      assert.are.equal("start", received[1].action)
    end)

    it("意図的に停止したときは切断として扱わない", function()
      -- jobstop と外部からの終了は同じ終了コードになるため、停止フラグで区別する。
      local disconnects = {}
      local subscription = events.subscribe({
        on_event = function() end,
        on_disconnect = function(intentional)
          table.insert(disconnects, intentional)
        end,
      })

      subscription.stop()
      started[1].handlers.on_exit(143)

      assert.are.same({ true }, disconnects)
    end)

    it("予期しない終了は切断として通知する", function()
      local disconnects = {}
      events.subscribe({
        on_event = function() end,
        on_disconnect = function(intentional)
          table.insert(disconnects, intentional)
        end,
      })

      started[1].handlers.on_exit(143)

      assert.are.same({ false }, disconnects)
    end)

    it("停止すると生存していない扱いになる", function()
      local subscription = events.subscribe({ on_event = function() end })
      assert.is_true(subscription.is_alive())

      subscription.stop()

      assert.is_false(subscription.is_alive())
    end)

    it("停止したジョブはジョブ台帳から外れる", function()
      local jobs = require("docker.handlers.jobs")
      jobs._reset()
      jobs._set_stopper(function() end)

      local subscription = events.subscribe({ on_event = function() end })
      assert.are.same({ 901 }, jobs.list())

      subscription.stop()

      assert.are.same({}, jobs.list())
    end)
  end)
end)
