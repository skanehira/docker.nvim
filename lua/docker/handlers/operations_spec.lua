local operations = require("docker.handlers.operations")

describe("docker.handlers.operations", function()
  before_each(function()
    operations._reset()
  end)

  describe("begin", function()
    it("実行中でない操作は受け付ける", function()
      assert.is_true(operations.begin("abc", "start"))
    end)

    it("同一対象の同一操作は二重に受け付けない", function()
      -- BR-009: 同じ対象への同種の操作は同時に 1 つまで。
      operations.begin("abc", "start")

      assert.is_false(operations.begin("abc", "start"))
    end)

    it("同一対象でも別の操作は受け付ける", function()
      operations.begin("abc", "start")

      assert.is_true(operations.begin("abc", "logs"))
    end)

    it("別の対象への同じ操作は受け付ける", function()
      operations.begin("abc", "start")

      assert.is_true(operations.begin("def", "start"))
    end)
  end)

  describe("finish", function()
    it("完了すると同じ操作を再び受け付ける", function()
      operations.begin("abc", "start")

      operations.finish("abc", "start")

      assert.is_true(operations.begin("abc", "start"))
    end)

    it("実行していない操作を完了させても他に影響しない", function()
      operations.begin("abc", "start")

      operations.finish("abc", "stop")

      assert.is_false(operations.begin("abc", "start"), "start は実行中のままであること")
    end)
  end)

  describe("is_running", function()
    it("受け付けた操作は実行中になる", function()
      operations.begin("abc", "start")

      assert.is_true(operations.is_running("abc", "start"))
    end)

    it("完了した操作は実行中でなくなる", function()
      operations.begin("abc", "start")
      operations.finish("abc", "start")

      assert.is_false(operations.is_running("abc", "start"))
    end)

    it("一度も受け付けていない操作は実行中でない", function()
      assert.is_false(operations.is_running("abc", "start"))
    end)
  end)

  describe("has_any", function()
    it("対象に実行中の操作があるかを返す", function()
      assert.is_false(operations.has_any("abc"))

      operations.begin("abc", "start")

      assert.is_true(operations.has_any("abc"))
    end)

    it("すべて完了すると実行中でなくなる", function()
      operations.begin("abc", "start")
      operations.begin("abc", "logs")

      operations.finish("abc", "start")
      assert.is_true(operations.has_any("abc"), "logs がまだ実行中")
      operations.finish("abc", "logs")

      assert.is_false(operations.has_any("abc"))
    end)
  end)
end)
