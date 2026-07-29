local events = require("docker.adapters.docker.events")
local jobs = require("docker.handlers.jobs")

describe("イベント購読の切断と回復", function()
  local started
  local waits
  local next_job_id

  --- 待機を偽の時計にする。実時間を待たずに再試行の挙動を検査する。
  local function fire_pending_waits()
    local pending = waits
    waits = {}
    for _, entry in ipairs(pending) do
      entry.callback()
    end
  end

  before_each(function()
    jobs._reset()
    jobs._set_stopper(function() end)
    started, waits = {}, {}
    next_job_id = 900
    events._set_starter(function(cmd, handlers)
      next_job_id = next_job_id + 1
      table.insert(started, { cmd = cmd, handlers = handlers, job_id = next_job_id })
      return next_job_id
    end)
    events._set_waiter(function(delay, callback)
      table.insert(waits, { delay = delay, callback = callback })
    end)
  end)

  after_each(function()
    events._set_starter(nil)
    events._set_waiter(nil)
    jobs._reset()
  end)

  ---@param opts table|nil
  local function subscribe(opts)
    return events.subscribe(vim.tbl_extend("force", { on_event = function() end }, opts or {}))
  end

  it("予期しない切断を検知して通知する", function()
    local disconnects = 0
    subscribe({
      on_disconnect = function(intentional)
        if not intentional then
          disconnects = disconnects + 1
        end
      end,
    })

    started[1].handlers.on_exit(1)

    assert.are.equal(1, disconnects)
  end)

  it("切断すると待機してから再購読する", function()
    subscribe({})
    assert.are.equal(1, #started)

    started[1].handlers.on_exit(1)
    fire_pending_waits()

    assert.are.equal(2, #started, "再購読が発行されること")
  end)

  it("再購読では直前に受信したイベントの時刻から再開する", function()
    subscribe({})
    started[1].handlers.on_stdout(vim.json.encode({
      Type = "container",
      Action = "start",
      Actor = { ID = "abc" },
      time = 1785000123,
    }) .. "\n")

    started[1].handlers.on_exit(1)
    fire_pending_waits()

    assert.are.same({ "docker", "events", "--format", "{{json .}}", "--since", "1785000123" }, started[2].cmd)
  end)

  it("待機時間を延ばしながら最大5回まで再試行する", function()
    subscribe({})

    local delays = {}
    for attempt = 1, 5 do
      started[attempt].handlers.on_exit(1)
      table.insert(delays, waits[1].delay)
      fire_pending_waits()
    end

    assert.are.same({ 1000, 2000, 4000, 8000, 16000 }, delays)
    assert.are.equal(6, #started, "初回 + 再試行 5 回")
  end)

  it("5回失敗すると諦めて手動更新を促す", function()
    local gave_up = 0
    subscribe({
      on_giveup = function()
        gave_up = gave_up + 1
      end,
    })

    for attempt = 1, 6 do
      started[attempt].handlers.on_exit(1)
      fire_pending_waits()
    end

    assert.are.equal(1, gave_up)
    assert.are.equal(6, #started, "6 回目の失敗では再購読しない")
  end)

  it("再購読に成功すると全件再取得を要求する", function()
    -- 待機中のイベントは取りこぼすため、購読の再開だけでは整合しない。
    local resyncs = 0
    subscribe({
      on_reconnect = function()
        resyncs = resyncs + 1
      end,
    })

    started[1].handlers.on_exit(1)
    fire_pending_waits()

    assert.are.equal(1, resyncs)
  end)

  it("再購読に成功すると再試行の回数が戻る", function()
    subscribe({})

    -- 4 回失敗した後に成功し、また切断されたら 1 秒待機からやり直す
    for attempt = 1, 4 do
      started[attempt].handlers.on_exit(1)
      fire_pending_waits()
    end
    -- イベントが 1 件届けば復旧とみなす (ジョブが起動できただけでは復旧ではない)
    started[5].handlers.on_stdout(vim.json.encode({
      Type = "container",
      Action = "start",
      Actor = { ID = "abc" },
      time = 1785000999,
    }) .. "\n")
    started[5].handlers.on_exit(1)

    assert.are.equal(1000, waits[1].delay)
  end)

  it("意図的に停止したときは再購読しない", function()
    local subscription = subscribe({})

    subscription.stop()
    started[1].handlers.on_exit(143)
    fire_pending_waits()

    assert.are.equal(1, #started)
  end)

  it("停止した後に届いたチャンクはイベントとして配送しない", function()
    local received = 0
    local subscription = subscribe({
      on_event = function()
        received = received + 1
      end,
    })

    subscription.stop()
    started[1].handlers.on_stdout(vim.json.encode({
      Type = "container",
      Action = "start",
      Actor = { ID = "abc" },
      time = 1,
    }) .. "\n")

    assert.are.equal(0, received)
  end)

  it("ジョブの起動に失敗したときも切断として通知する", function()
    -- 失敗を黙って捨てると、購読していないのに購読中のように見える。
    events._set_starter(function()
      return 0
    end)
    local disconnects = 0

    subscribe({
      on_disconnect = function()
        disconnects = disconnects + 1
      end,
    })

    assert.are.equal(1, disconnects)
  end)

  it("再購読で開始したジョブも台帳に載る", function()
    subscribe({})
    assert.are.same({ 901 }, jobs.list())

    started[1].handlers.on_exit(1)
    fire_pending_waits()

    assert.are.same({ 902 }, jobs.list())
  end)
end)
