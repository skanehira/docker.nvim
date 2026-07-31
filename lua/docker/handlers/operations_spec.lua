local operations = require("docker.handlers.operations")

describe("docker.handlers.operations", function()
  before_each(function()
    operations._reset()
  end)

  describe("begin", function()
    it("accepts an operation that is not already running", function()
      assert.is_true(operations.begin("abc", "start"))
    end)

    it("does not accept the same operation twice for the same target", function()
      -- BR-009: at most one operation of the same kind may run against the same target at a time.
      operations.begin("abc", "start")

      assert.is_false(operations.begin("abc", "start"))
    end)

    it("accepts a different operation even for the same target", function()
      operations.begin("abc", "start")

      assert.is_true(operations.begin("abc", "logs"))
    end)

    it("accepts the same operation for a different target", function()
      operations.begin("abc", "start")

      assert.is_true(operations.begin("def", "start"))
    end)
  end)

  describe("finish", function()
    it("accepts the same operation again once it has finished", function()
      operations.begin("abc", "start")

      operations.finish("abc", "start")

      assert.is_true(operations.begin("abc", "start"))
    end)

    it("finishing an operation that is not running affects nothing else", function()
      operations.begin("abc", "start")

      operations.finish("abc", "stop")

      assert.is_false(operations.begin("abc", "start"), "start must stay running")
    end)
  end)

  describe("is_running", function()
    it("reports an accepted operation as running", function()
      operations.begin("abc", "start")

      assert.is_true(operations.is_running("abc", "start"))
    end)

    it("stops reporting a finished operation as running", function()
      operations.begin("abc", "start")
      operations.finish("abc", "start")

      assert.is_false(operations.is_running("abc", "start"))
    end)

    it("does not report an operation that was never accepted as running", function()
      assert.is_false(operations.is_running("abc", "start"))
    end)
  end)

  describe("has_any", function()
    it("returns whether the target has an operation running", function()
      assert.is_false(operations.has_any("abc"))

      operations.begin("abc", "start")

      assert.is_true(operations.has_any("abc"))
    end)

    it("stops reporting the target as running once every operation has finished", function()
      operations.begin("abc", "start")
      operations.begin("abc", "logs")

      operations.finish("abc", "start")
      assert.is_true(operations.has_any("abc"), "logs is still running")
      operations.finish("abc", "logs")

      assert.is_false(operations.has_any("abc"))
    end)
  end)
end)
