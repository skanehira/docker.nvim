local version = require("docker.version")

describe("docker.version", function()
  describe("supported", function()
    it("要求バージョンちょうどなら対応している", function()
      assert.is_true(version.supported({ major = 0, minor = 10, patch = 0 }))
    end)

    it("要求バージョンより新しければ対応している", function()
      assert.is_true(version.supported({ major = 0, minor = 11, patch = 2 }))
    end)

    it("メジャーが上なら対応している", function()
      assert.is_true(version.supported({ major = 1, minor = 0, patch = 0 }))
    end)

    it("要求バージョンより古ければ対応していない", function()
      assert.is_false(version.supported({ major = 0, minor = 9, patch = 5 }))
    end)

    it("実行中のNeovimは対応している", function()
      -- 開発・CI で使う Neovim が要求を満たしていること自体の確認。
      assert.is_true(version.supported())
    end)
  end)

  describe("requirement_message", function()
    it("必要なバージョンと実際のバージョンを示す", function()
      local msg = version.requirement_message({ major = 0, minor = 9, patch = 5 })

      assert.is_truthy(msg:find("0.10", 1, true), msg)
      assert.is_truthy(msg:find("0.9.5", 1, true), msg)
    end)
  end)
end)
