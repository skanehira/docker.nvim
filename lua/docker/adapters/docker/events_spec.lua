local events = require("docker.adapters.docker.events")

--- The JSON that docker events emits as one line.
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
    it("returns one event when a single chunk carries one complete line", function()
      local decoder = events.new_decoder()

      local got = decoder:push(raw_line() .. "\n")

      assert.are.equal(1, #got)
      assert.are.equal("container", got[1].type)
      assert.are.equal("start", got[1].action)
    end)

    it("assembles a complete event from chunks split in the middle of a line", function()
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

    it("returns every event when several lines arrive in one chunk", function()
      local decoder = events.new_decoder()

      local got = decoder:push(raw_line({ id = "a", Actor = { ID = "a" } }) .. "\n" .. raw_line({
        id = "b",
        Actor = { ID = "b" },
      }) .. "\n")

      assert.are.equal(2, #got)
      assert.are.equal("a", got[1].id)
      assert.are.equal("b", got[2].id)
    end)

    it("returns no event until a newline arrives", function()
      local decoder = events.new_decoder()

      assert.are.same({}, decoder:push(raw_line()))
    end)

    it("assembles even a huge single line", function()
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

    it("skips empty lines", function()
      local decoder = events.new_decoder()

      local got = decoder:push("\n\n" .. raw_line() .. "\n\n")

      assert.are.equal(1, #got)
    end)

    it("skips a line that cannot be parsed and processes the following ones", function()
      local decoder = events.new_decoder()

      local got = decoder:push("not json\n" .. raw_line() .. "\n")

      assert.are.equal(1, #got)
    end)
  end)

  describe("extracting an event", function()
    it("uses time with second precision and does not carry timeNano over", function()
      -- timeNano is turned into a floating point number by vim.json.decode and its low digits are
      -- lost, so it is not used as the resubscription starting point. We compare the whole event to
      -- show that it is not mixed in.
      local decoder = events.new_decoder()

      local got = decoder:push(raw_line({ time = 1785000000 }) .. "\n")

      assert.are.same({
        type = "container",
        action = "start",
        id = "abc123",
        time = 1785000000,
      }, got[1])
    end)

    it("takes the container ID from the ID of Actor", function()
      local decoder = events.new_decoder()

      local got = decoder:push(raw_line({ Actor = { ID = "container-id" } }) .. "\n")

      assert.are.equal("container-id", got[1].id)
    end)

    it("takes the volume name from the ID of Actor", function()
      -- In a volume event the name is in Actor.ID, not in Actor.Attributes.name.
      local decoder = events.new_decoder()

      local got = decoder:push(raw_line({
        Type = "volume",
        Action = "create",
        Actor = { ID = "my-volume", Attributes = { driver = "local" } },
      }) .. "\n")

      assert.are.equal("volume", got[1].type)
      assert.are.equal("my-volume", got[1].id)
    end)

    it("skips an event that has no Actor", function()
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

    it("subscribes to docker events in JSON format", function()
      events.subscribe({ on_event = function() end })

      assert.are.same({ "docker", "events", "--format", "{{json .}}" }, started[1].cmd)
    end)

    it("passes the resume position when since is specified", function()
      events.subscribe({ since = "1785000000", on_event = function() end })

      assert.are.same({ "docker", "events", "--format", "{{json .}}", "--since", "1785000000" }, started[1].cmd)
    end)

    it("notifies the events it receives", function()
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

    it("does not treat an intentional stop as a disconnect", function()
      -- jobstop and a termination from the outside produce the same exit code, so we tell them apart
      -- with the stop flag.
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

    it("notifies an unexpected termination as a disconnect", function()
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

    it("is treated as not alive once it is stopped", function()
      local subscription = events.subscribe({ on_event = function() end })
      assert.is_true(subscription.is_alive())

      subscription.stop()

      assert.is_false(subscription.is_alive())
    end)

    it("removes a stopped job from the job ledger", function()
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
