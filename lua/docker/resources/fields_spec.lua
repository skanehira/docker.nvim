local fields = require("docker.resources.fields")

--- Raw container data as obtained from the list command. Only the given entries are overridden.
---@param overrides table|nil
---@return table
local function container(overrides)
  return vim.tbl_extend("force", {
    id = "abc123",
    name = "web",
    image = "alpine",
    state = "running",
    status = "Up 5 days",
    ports = "",
    command = '"sleep 600"',
    created_at = "2026-07-29 10:00:00 +0900 JST",
    compose_project = "",
    compose_service = "",
    compose_oneoff = "",
  }, overrides or {})
end

describe("docker.resources.fields", function()
  describe("is_compose", function()
    it("reports a container as compose-managed when both project name and service name are present", function()
      local item = container({ compose_project = "shop", compose_service = "web", compose_oneoff = "False" })

      assert.is_true(fields.is_compose(item))
    end)

    it("does not report a container without labels as compose-managed", function()
      assert.is_false(fields.is_compose(container()))
    end)

    it("does not report a container as compose-managed when only the project name is set", function()
      assert.is_false(fields.is_compose(container({ compose_project = "shop" })))
    end)

    it("does not report a container as compose-managed when only the service name is set", function()
      assert.is_false(fields.is_compose(container({ compose_service = "web" })))
    end)
  end)

  describe("is_oneoff", function()
    it("reports a container as one-off when the oneoff label is True", function()
      local item = container({ compose_project = "shop", compose_service = "web", compose_oneoff = "True" })

      assert.is_true(fields.is_oneoff(item))
    end)

    it("does not report a container as one-off when the oneoff label is False", function()
      assert.is_false(fields.is_oneoff(container({ compose_oneoff = "False" })))
    end)

    it("does not report a container as one-off when the oneoff label is empty", function()
      assert.is_false(fields.is_oneoff(container()))
    end)
  end)

  describe("service_of", function()
    it("returns the project and service pair for a regular compose-managed container", function()
      local item = container({ compose_project = "shop", compose_service = "web", compose_oneoff = "False" })

      assert.are.same({ project = "shop", service = "web" }, fields.service_of(item))
    end)

    it("does not tie a one-off container to a service", function()
      -- BR-006: a one-off container created by `docker compose run` is not the instance of a service.
      local item = container({ compose_project = "shop", compose_service = "web", compose_oneoff = "True" })

      assert.is_nil(fields.service_of(item))
    end)

    it("does not tie a container that did not come from compose to a service", function()
      assert.is_nil(fields.service_of(container()))
    end)
  end)

  describe("ports", function()
    it("returns an empty string when there are no published ports", function()
      assert.are.equal("", fields.ports(container()))
    end)

    it("returns the published ports string as is", function()
      local item = container({ ports = "0.0.0.0:8080->80/tcp" })

      assert.are.equal("0.0.0.0:8080->80/tcp", fields.ports(item))
    end)
  end)

  describe("state", function()
    it("returns the state string as is", function()
      assert.are.equal("running", fields.state(container()))
    end)

    it("returns an empty string when the state is missing", function()
      local item = container()
      item.state = nil

      assert.are.equal("", fields.state(item))
    end)
  end)
end)
