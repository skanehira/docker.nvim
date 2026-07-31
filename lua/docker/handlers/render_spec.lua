local render = require("docker.handlers.render")

describe("docker.handlers.render", function()
  local scheduled

  --- A fake clock. Inspects the debounce behavior without waiting for real time.
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

  --- Fires the timers that have been set up and not yet stopped.
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
    it("does not draw immediately after the request", function()
      local drawn = 0

      render.request("container", function()
        drawn = drawn + 1
      end)

      assert.are.equal(0, drawn)
    end)

    it("draws once the wait time has passed", function()
      local drawn = 0
      render.request("container", function()
        drawn = drawn + 1
      end)

      fire_pending()

      assert.are.equal(1, drawn)
    end)

    it("coalesces consecutive requests into one", function()
      -- docker events carries events for the whole daemon, so without coalescing
      -- the rendering spins uselessly on every bulk change.
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

    it("runs the draw passed last when requests are coalesced", function()
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

    it("does not coalesce requests with different keys", function()
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

    it("coalesces afresh for requests made after a draw", function()
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

  describe("wait time", function()
    it("is sized so the render request goes out within 1 second of receiving an event", function()
      -- G9: an operation made by another process is reflected in the list within 1 second.
      -- The breakdown is "debounce + refetching the target (measured 20-60ms) + rendering (measured 2ms)".
      render.request("container", function() end)

      assert.are.equal(render.DELAY_MS, scheduled[1].delay)
      assert.is_true(render.DELAY_MS < 1000, "must leave headroom against the 1 second goal")
      assert.is_true(render.DELAY_MS >= 50, "must be wide enough to coalesce bulk changes")
    end)
  end)

  describe("cancel", function()
    it("can cancel a pending render request", function()
      local drawn = 0
      render.request("container", function()
        drawn = drawn + 1
      end)

      render.cancel("container")
      fire_pending()

      assert.are.equal(0, drawn)
    end)

    it("still accepts a new request after a cancellation", function()
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
