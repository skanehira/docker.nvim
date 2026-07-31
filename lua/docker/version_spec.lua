local version = require("docker.version")

describe("docker.version", function()
  describe("supported", function()
    it("is supported when the version is exactly the required one", function()
      assert.is_true(version.supported({ major = 0, minor = 10, patch = 0 }))
    end)

    it("is supported when the version is newer than the required one", function()
      assert.is_true(version.supported({ major = 0, minor = 11, patch = 2 }))
    end)

    it("is supported when the major version is higher", function()
      assert.is_true(version.supported({ major = 1, minor = 0, patch = 0 }))
    end)

    it("is not supported when the version is older than the required one", function()
      assert.is_false(version.supported({ major = 0, minor = 9, patch = 5 }))
    end)

    it("supports the running Neovim", function()
      -- Confirms that the Neovim used for development and CI itself meets the requirement.
      assert.is_true(version.supported())
    end)
  end)

  describe("requirement_message", function()
    it("states both the required version and the actual version", function()
      local msg = version.requirement_message({ major = 0, minor = 9, patch = 5 })

      assert.is_truthy(msg:find("0.10", 1, true), msg)
      assert.is_truthy(msg:find("0.9.5", 1, true), msg)
    end)
  end)
end)
