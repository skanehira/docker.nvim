local services = require("docker.resources.services")

---@param overrides table|nil
---@return table
local function container(overrides)
  return vim.tbl_extend("force", {
    id = "abc123",
    name = "shop-web-1",
    image = "alpine",
    state = "running",
    status = "Up 5 days",
    ports = "",
    command = '"sleep"',
    created_at = "now",
    compose_project = "shop",
    compose_service = "web",
    compose_oneoff = "False",
  }, overrides or {})
end

---@param names string[]
---@return docker.ComposeProject
local function project(names)
  return { name = "shop", working_dir = "/work/shop", service_names = names }
end

describe("docker.resources.services", function()
  describe("assemble", function()
    it("matches service names against containers by label", function()
      local items = services.assemble(project({ "web" }), { container() })

      assert.are.same({
        {
          project = "shop",
          name = "web",
          container = "shop-web-1",
          container_id = "abc123",
          status = "running",
          working_dir = "/work/shop",
        },
      }, items)
    end)

    it("carries the location of the compose file on every row", function()
      -- Lifecycle operations can only run where the compose file is readable, so every row carries
      -- that location for the operation side to reference.
      local items = services.assemble(project({ "web", "never-started" }), { container() })

      assert.are.equal("/work/shop", items[1].working_dir)
      assert.are.equal("/work/shop", items[2].working_dir)
    end)

    it("gives a service with no matching container the state none", function()
      -- BR-005: services that are defined but not started are listed too.
      local items = services.assemble(project({ "web", "never-started" }), { container() })

      local by_name = {}
      for _, item in ipairs(items) do
        by_name[item.name] = item
      end
      assert.are.equal("none", by_name["never-started"].status)
      assert.are.equal("", by_name["never-started"].container)
      assert.are.equal("running", by_name["web"].status)
    end)

    it("does not tie a one-off container to a service", function()
      -- BR-006: a container created by `docker compose run` is not the instance of a service.
      local items = services.assemble(project({ "worker" }), {
        container({ id = "one", name = "shop-worker-run-abc", compose_service = "worker", compose_oneoff = "True" }),
      })

      assert.are.equal(1, #items)
      assert.are.equal("none", items[1].status)
      assert.are.equal("", items[1].container)
    end)

    it("uses the real container when one exists even if a one-off container is present", function()
      local items = services.assemble(project({ "worker" }), {
        container({ id = "one", name = "shop-worker-run-abc", compose_service = "worker", compose_oneoff = "True" }),
        container({ id = "real", name = "shop-worker-1", compose_service = "worker", compose_oneoff = "False" }),
      })

      assert.are.equal(1, #items)
      assert.are.equal("shop-worker-1", items[1].container)
      assert.are.equal("running", items[1].status)
    end)

    it("lets a running container represent a service that has several containers", function()
      -- On a scaled service, a stopped first container would make it look stopped even though a
      -- running replica exists.
      local items = services.assemble(project({ "web" }), {
        container({ id = "1", name = "shop-web-1", state = "exited" }),
        container({ id = "2", name = "shop-web-2", state = "running" }),
      })

      assert.are.equal("running", items[1].status)
      assert.are.equal("shop-web-2", items[1].container)
    end)

    it("shows that state when every container is stopped", function()
      local items = services.assemble(project({ "web" }), {
        container({ id = "1", name = "shop-web-1", state = "exited" }),
        container({ id = "2", name = "shop-web-2", state = "exited" }),
      })

      assert.are.equal("exited", items[1].status)
    end)

    it("does not tie a container of another project to a service", function()
      local items = services.assemble(project({ "web" }), {
        container({ compose_project = "other", name = "other-web-1" }),
      })

      assert.are.equal("none", items[1].status)
    end)

    it("ignores a container that did not come from compose", function()
      local items = services.assemble(project({ "web" }), {
        container({ compose_project = "", compose_service = "", name = "plain" }),
      })

      assert.are.equal("none", items[1].status)
    end)

    it("does not list a container whose service is not in the definitions", function()
      -- Do not show the remains of a service that was removed from compose.yaml.
      local items = services.assemble(project({ "web" }), {
        container(),
        container({ id = "ghost", name = "shop-ghost-1", compose_service = "ghost" }),
      })

      assert.are.equal(1, #items)
      assert.are.equal("web", items[1].name)
    end)

    it("orders the services as they appear in the definitions", function()
      local items = services.assemble(project({ "alpha", "mid", "zeta" }), {})

      local names = {}
      for _, item in ipairs(items) do
        table.insert(names, item.name)
      end
      assert.are.same({ "alpha", "mid", "zeta" }, names)
    end)

    it("reflects the state of a stopped container as it is", function()
      local items = services.assemble(project({ "web" }), {
        container({ state = "exited", status = "Exited (0) 1 minute ago" }),
      })

      assert.are.equal("exited", items[1].status)
    end)

    it("returns nothing when there are 0 services", function()
      assert.are.same({}, services.assemble(project({}), { container() }))
    end)
  end)

  describe("derive_service_names", function()
    -- For a project whose compose file cannot be read the definitions cannot be looked up.
    -- In that case the service names are derived from the container labels.
    it("extracts the service names from the containers of that project", function()
      local names = services.derive_service_names("shop", {
        container({ compose_service = "web" }),
        container({ id = "2", compose_service = "db" }),
      })

      assert.are.same({ "db", "web" }, names)
    end)

    it("collapses several containers of the same service into one", function()
      local names = services.derive_service_names("shop", {
        container({ id = "1", name = "shop-web-1", compose_service = "web" }),
        container({ id = "2", name = "shop-web-2", compose_service = "web" }),
      })

      assert.are.same({ "web" }, names)
    end)

    it("does not include containers of another project", function()
      local names = services.derive_service_names("shop", {
        container({ compose_service = "web" }),
        container({ id = "2", compose_project = "blog", compose_service = "cms" }),
      })

      assert.are.same({ "web" }, names)
    end)

    it("does not count a one-off container as a service", function()
      -- BR-006: a container created by `docker compose run` is not the instance of a service.
      local names = services.derive_service_names("shop", {
        container({ compose_service = "worker", compose_oneoff = "True" }),
      })

      assert.are.same({}, names)
    end)

    it("returns nothing when there is no matching container", function()
      assert.are.same({}, services.derive_service_names("shop", {}))
    end)
  end)

  describe("assemble_all", function()
    it("merges the services of several projects into a single list", function()
      local items = services.assemble_all({
        { name = "shop", working_dir = "/work/shop", service_names = { "web" } },
        { name = "blog", working_dir = "/work/blog", service_names = { "cms" } },
      }, {
        container({ compose_project = "shop", compose_service = "web" }),
        container({ id = "b1", name = "blog-cms-1", compose_project = "blog", compose_service = "cms" }),
      })

      assert.are.same({
        {
          project = "blog",
          name = "cms",
          container = "blog-cms-1",
          container_id = "b1",
          status = "running",
          working_dir = "/work/blog",
        },
        {
          project = "shop",
          name = "web",
          container = "shop-web-1",
          container_id = "abc123",
          status = "running",
          working_dir = "/work/shop",
        },
      }, items)
    end)

    it("orders the projects by name", function()
      -- The order of the source can change from run to run. Do not let the row order change per run.
      local items = services.assemble_all({
        { name = "zeta", working_dir = "/z", service_names = { "a" } },
        { name = "alpha", working_dir = "/a", service_names = { "a" } },
        { name = "mid", working_dir = "/m", service_names = { "a" } },
      }, {})

      local names = {}
      for _, item in ipairs(items) do
        table.insert(names, item.project)
      end
      assert.are.same({ "alpha", "mid", "zeta" }, names)
    end)

    it("lists both when services with the same name exist in different projects", function()
      local items = services.assemble_all({
        { name = "shop", working_dir = "/work/shop", service_names = { "web" } },
        { name = "blog", working_dir = "/work/blog", service_names = { "web" } },
      }, {})

      assert.are.equal(2, #items)
      assert.are.equal("blog", items[1].project)
      assert.are.equal("shop", items[2].project)
    end)

    it("returns nothing when there are 0 projects", function()
      assert.are.same({}, services.assemble_all({}, { container() }))
    end)
  end)
end)
