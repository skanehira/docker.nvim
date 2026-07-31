local events = require("docker.adapters.docker.events")
local jobs = require("docker.handlers.jobs")

describe("disconnect and recovery of the event subscription", function()
  local started
  local waits
  local next_job_id

  --- Turns waiting into a fake clock. Inspects the retry behavior without waiting real time.
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

  it("detects an unexpected disconnect and notifies it", function()
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

  it("waits and then resubscribes after a disconnect", function()
    subscribe({})
    assert.are.equal(1, #started)

    started[1].handlers.on_exit(1)
    fire_pending_waits()

    assert.are.equal(2, #started, "a resubscription must be issued")
  end)

  it("resumes from the time of the last received event when it resubscribes", function()
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

  it("retries up to 5 times with a growing wait time", function()
    subscribe({})

    local delays = {}
    for attempt = 1, 5 do
      started[attempt].handlers.on_exit(1)
      table.insert(delays, waits[1].delay)
      fire_pending_waits()
    end

    assert.are.same({ 1000, 2000, 4000, 8000, 16000 }, delays)
    assert.are.equal(6, #started, "the first attempt + 5 retries")
  end)

  it("gives up and prompts for a manual refresh after 5 failures", function()
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
    assert.are.equal(6, #started, "it must not resubscribe on the 6th failure")
  end)

  it("requests a full refetch once resubscription succeeds", function()
    -- Events during the wait are missed, so resuming the subscription alone does not reconcile it.
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

  it("resets the retry count once resubscription succeeds", function()
    subscribe({})

    -- It succeeds after 4 failures, and when it is disconnected again it starts over from a 1 second wait
    for attempt = 1, 4 do
      started[attempt].handlers.on_exit(1)
      fire_pending_waits()
    end
    -- One arriving event counts as recovery (the job merely having started is not recovery)
    started[5].handlers.on_stdout(vim.json.encode({
      Type = "container",
      Action = "start",
      Actor = { ID = "abc" },
      time = 1785000999,
    }) .. "\n")
    started[5].handlers.on_exit(1)

    assert.are.equal(1000, waits[1].delay)
  end)

  it("does not resubscribe after an intentional stop", function()
    local subscription = subscribe({})

    subscription.stop()
    started[1].handlers.on_exit(143)
    fire_pending_waits()

    assert.are.equal(1, #started)
  end)

  it("does not deliver a chunk that arrives after the stop as an event", function()
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

  it("notifies a disconnect also when the job fails to start", function()
    -- Silently dropping the failure would make it look subscribed while it is not.
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

  it("registers a job started by resubscription in the ledger as well", function()
    subscribe({})
    assert.are.same({ 901 }, jobs.list())

    started[1].handlers.on_exit(1)
    fire_pending_waits()

    assert.are.same({ 902 }, jobs.list())
  end)
end)
