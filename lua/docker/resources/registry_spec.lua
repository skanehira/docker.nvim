local registry = require("docker.resources.registry")

--- Raw container data as obtained from the list command. Only the given entries are overridden.
---@param overrides table|nil
---@return table
local function container(overrides)
  return vim.tbl_extend("force", {
    id = "abc123def456",
    name = "web",
    image = "alpine:3.20",
    state = "running",
    status = "Up 5 days",
    ports = "0.0.0.0:8080->80/tcp",
    command = '"sleep 600"',
    created_at = "2026-07-29 10:00:00 +0900 JST",
    compose_project = "",
    compose_service = "",
    compose_oneoff = "",
  }, overrides or {})
end

---@param def docker.ResourceDefinition
---@param item table
---@return table<string, string>
local function columns_of(def, item)
  local values = {}
  for _, column in ipairs(def.columns) do
    values[column.header] = column.value(item)
  end
  return values
end

describe("docker.resources.registry", function()
  describe("get", function()
    it("returns nil when an unknown kind is passed", function()
      assert.is_nil(registry.get("nonexistent"))
    end)
  end)

  describe("subcommands", function()
    it("returns the Ex command arguments corresponding to the defined kinds", function()
      assert.are.same({ "containers", "images", "volumes", "networks", "services" }, registry.subcommands())
    end)
  end)

  describe("the container definition", function()
    ---@type docker.ResourceDefinition
    local def

    before_each(function()
      def = assert(registry.get("container"))
    end)

    it("adds -a to the list arguments so that stopped containers are included", function()
      -- BR-022: stopped containers are included in the list too.
      assert.is_truthy(vim.tbl_contains(assert(def.list_args)(), "-a"))
    end)

    it("adds --no-trunc to the list arguments to prevent truncation", function()
      -- Without it the ID is truncated to 12 characters and Command to 20.
      assert.is_truthy(vim.tbl_contains(assert(def.list_args)(), "--no-trunc"))
    end)

    it("uses ps as the subcommand for listing", function()
      assert.are.equal("ps", assert(def.list_args)()[1])
    end)

    it("does not include the size in the list format", function()
      -- Referencing .Size makes size computation run and increases the execution time.
      local args = table.concat(assert(def.list_args)(), " ")

      assert.is_nil(args:find(".Size", 1, true))
    end)

    it("takes the compose labels in the list format by naming the key", function()
      -- Splitting `Labels` grabs the wrong value on commas inside label values and on planted fake labels.
      local args = table.concat(assert(def.list_args)(), " ")

      assert.is_truthy(args:find('(.Label "com.docker.compose.project")', 1, true))
      assert.is_truthy(args:find('(.Label "com.docker.compose.service")', 1, true))
      assert.is_truthy(args:find('(.Label "com.docker.compose.oneoff")', 1, true))
      -- The location of the compose file. Used to look up the definition from outside the project.
      assert.is_truthy(args:find('(.Label "com.docker.compose.project.working_dir")', 1, true))
      assert.is_nil(args:find("{{json .Labels}}", 1, true))
    end)

    it("returns the container ID as the identifier", function()
      assert.are.equal("abc123def456", def.id(container()))
    end)

    it("orders the columns as NAME_PROJECT_SERVICE_IMAGE_STATUS_PORTS", function()
      local headers = {}
      for _, column in ipairs(def.columns) do
        table.insert(headers, column.header)
      end

      assert.are.same({ "NAME", "PROJECT", "SERVICE", "IMAGE", "STATUS", "PORTS" }, headers)
    end)

    it("fills PROJECT and SERVICE for a compose-managed container", function()
      local item = container({
        compose_project = "shop",
        compose_service = "web",
        compose_oneoff = "False",
      })

      assert.are.same({
        NAME = "web",
        IMAGE = "alpine:3.20",
        STATUS = "Up 5 days",
        PORTS = "0.0.0.0:8080->80/tcp",
        PROJECT = "shop",
        SERVICE = "web",
      }, columns_of(def, item))
    end)

    it("leaves PROJECT and SERVICE blank for a container that did not come from compose", function()
      assert.are.same({
        NAME = "web",
        IMAGE = "alpine:3.20",
        STATUS = "Up 5 days",
        PORTS = "0.0.0.0:8080->80/tcp",
        PROJECT = "",
        SERVICE = "",
      }, columns_of(def, container()))
    end)

    it("keeps PROJECT blank even when a fake project name is planted in a label value", function()
      -- The raw data is collected by naming the key through `.Label`, so even when a label value
      -- contains `,com.docker.compose.project=SPOOFED,` it stays an empty string.
      local item = container({ compose_project = "", compose_service = "" })

      assert.are.equal("", columns_of(def, item).PROJECT)
    end)

    it("points the state column position at STATUS", function()
      assert.are.equal(5, def.status_column)
      assert.are.equal("STATUS", def.columns[def.status_column].header)
    end)

    it("returns the state field of the raw data as the state", function()
      assert.are.equal("exited", def.status(container({ state = "exited" })))
    end)

    it("corresponds to the container type of docker events", function()
      assert.are.equal("container", def.event_type)
    end)

    it("uses containers as the Ex command argument", function()
      assert.are.equal("containers", def.subcommand)
    end)

    it("uses Containers as the display name", function()
      assert.are.equal("Containers", def.display_name)
    end)

    it("filters by ID in the arguments that fetch just one item again", function()
      local args = assert(def.item_args)("abc123")

      assert.are.equal("ps", args[1])
      assert.is_truthy(vim.tbl_contains(args, "--filter"))
      assert.is_truthy(vim.tbl_contains(args, "id=abc123"))
      assert.is_truthy(vim.tbl_contains(args, "-a"), "a stopped container must be fetchable again too")
      assert.is_truthy(vim.tbl_contains(args, "--no-trunc"))
    end)

    it("does not add force delete to the delete arguments", function()
      -- BR-002: let docker reject deleting a running container.
      assert.are.same({ "rm", "abc123def456" }, assert(def.delete_args)(container()))
    end)
  end)

  describe("the compose service definition", function()
    ---@type docker.ResourceDefinition
    local def

    before_each(function()
      def = assert(registry.get("service"))
    end)

    it("orders the columns as PROJECT_SERVICE_STATUS_CONTAINER", function()
      -- The list merges every project, so it shows which project a row belongs to.
      local headers = {}
      for _, column in ipairs(def.columns) do
        table.insert(headers, column.header)
      end

      assert.are.same({ "PROJECT", "SERVICE", "STATUS", "CONTAINER" }, headers)
    end)

    it("shows the project name of the row in the PROJECT column", function()
      local item = { project = "shop", name = "web", status = "running", container = "shop-web-1" }

      assert.are.equal("shop", def.columns[1].value(item))
    end)

    it("points the state column position at STATUS", function()
      assert.are.equal(3, def.status_column)
      assert.are.equal("STATUS", def.columns[def.status_column].header)
    end)

    it("uses the pair of project name and service name as the identifier", function()
      -- Do not let a service with the same name in another project collide.
      assert.are.equal("shop/web", def.id({ project = "shop", name = "web" }))
    end)

    it("obtains the list by assembling rather than by a single docker command", function()
      -- Matching the compose definitions against the container list is required (section 7.3).
      assert.is_truthy(def.load)
      assert.is_nil(def.list_args)
    end)

    it("updates on container events", function()
      -- The state of a service is determined by the state of its container.
      assert.are.equal("container", def.event_type)
    end)

    it("uses services as the Ex command argument", function()
      assert.are.equal("services", def.subcommand)
    end)

    it("looks up the keymaps of the service list", function()
      assert.are.equal("service_list", def.view_type)
    end)
  end)

  describe("the image, volume and network definitions", function()
    it("uses the expected list and delete arguments for images", function()
      local def = assert(registry.get("image"))

      local args = assert(def.list_args)()
      assert.are.same({ "image", "ls" }, { args[1], args[2] })
      assert.is_truthy(vim.tbl_contains(args, "--no-trunc"))
      -- `docker image ls` cannot handle .Label.
      assert.is_nil(table.concat(args, " "):find(".Label", 1, true))

      -- The Actor.ID of the event (a sha) does not correspond to the identifier (the tag
      -- reference), so everything is fetched again.
      -- `docker image ls` does not accept an id filter either (invalid filter 'id').
      assert.is_nil(def.item_args, "fetching just one item again is not used")
      assert.is_true(def.event_reload)

      -- Since the same image carries several tags, the identifier is the tag reference.
      assert.are.equal("alpine:3.20", def.id({ id = "i1", repository = "alpine", tag = "3.20" }))
      assert.are.equal("i1", def.id({ id = "i1", repository = "<none>", tag = "<none>" }))
      -- When the same image has several tags, deleting by ID targets the image itself, which
      -- cannot be deleted while another tag still uses it. If there is a tag, use the tag reference.
      assert.are.same(
        { "rmi", "alpine:3.20" },
        assert(def.delete_args)({ id = "img1", repository = "alpine", tag = "3.20" })
      )
      assert.are.same(
        { "rmi", "img1" },
        assert(def.delete_args)({ id = "img1", repository = "<none>", tag = "<none>" }),
        "an image without a tag is deleted by ID"
      )
    end)

    it("uses the expected column layout and values for images", function()
      local def = assert(registry.get("image"))
      local item = { id = "i1", repository = "alpine", tag = "3.20", size = "5MB", created_since = "2 days ago" }

      local values = {}
      for _, column in ipairs(def.columns) do
        table.insert(values, { column.header, column.value(item) })
      end

      assert.are.same({
        { "REPOSITORY", "alpine" },
        { "TAG", "3.20" },
        { "SIZE", "5MB" },
        { "CREATED", "2 days ago" },
      }, values)
    end)

    it("uses the expected column layout and values for volumes and networks", function()
      local volume = assert(registry.get("volume"))
      local vvalues = {}
      for _, column in ipairs(volume.columns) do
        table.insert(vvalues, { column.header, column.value({ name = "v1", driver = "local", mountpoint = "/m" }) })
      end
      assert.are.same({ { "NAME", "v1" }, { "DRIVER", "local" }, { "MOUNTPOINT", "/m" } }, vvalues)

      local network = assert(registry.get("network"))
      local nvalues = {}
      for _, column in ipairs(network.columns) do
        table.insert(
          nvalues,
          { column.header, column.value({ id = "n1", name = "bridge", driver = "bridge", scope = "local" }) }
        )
      end
      assert.are.same({ { "NAME", "bridge" }, { "DRIVER", "bridge" }, { "SCOPE", "local" } }, nvalues)
    end)

    it("uses the expected list and delete arguments for volumes", function()
      local def = assert(registry.get("volume"))

      local args = assert(def.list_args)()
      -- Without passing a format, docker falls back to its default table layout and it cannot be parsed.
      assert.are.same({
        "volume",
        "ls",
        "--format",
        '{"name":{{json .Name}},"driver":{{json .Driver}},"mountpoint":{{json .Mountpoint}}}',
      }, args)
      -- For a volume the name is the identifier (the name goes into Actor.ID in events too).
      assert.are.equal("vol1", def.id({ name = "vol1" }))
      assert.are.same({ "volume", "rm", "vol1" }, assert(def.delete_args)({ name = "vol1" }))
    end)

    it("uses the expected list and delete arguments for networks", function()
      local def = assert(registry.get("network"))

      local args = assert(def.list_args)()
      assert.are.same({
        "network",
        "ls",
        "--no-trunc",
        "--format",
        '{"id":{{json .ID}},"name":{{json .Name}},"driver":{{json .Driver}},"scope":{{json .Scope}}}',
      }, args)
      assert.are.same({ "network", "rm", "net1" }, assert(def.delete_args)({ id = "net1" }))
    end)

    it("does not exclude the built-in networks from deletion", function()
      -- Let docker decide whether deletion is allowed and present its error as it is (BR-016).
      local def = assert(registry.get("network"))

      assert.are.same({ "network", "rm", "bridge" }, assert(def.delete_args)({ id = "bridge", name = "bridge" }))
    end)

    it("corresponds to its own event type for each of them", function()
      assert.are.equal("image", assert(registry.get("image")).event_type)
      assert.are.equal("volume", assert(registry.get("volume")).event_type)
      assert.are.equal("network", assert(registry.get("network")).event_type)
    end)

    it("has no state column", function()
      -- Unlike containers and services, they have no notion of a state.
      for _, kind in ipairs({ "image", "volume", "network" }) do
        assert.is_nil(assert(registry.get(kind)).status_column, kind)
      end
    end)
  end)

  describe("the empty list display", function()
    it("has a message per kind saying that there are no items", function()
      local texts = {}
      for _, kind in ipairs({ "container", "image", "volume", "network", "service" }) do
        texts[kind] = assert(registry.get(kind)).empty_text
      end

      assert.are.same({
        container = "No containers",
        image = "No images",
        volume = "No volumes",
        network = "No networks",
        service = "No compose projects",
      }, texts)
    end)
  end)
end)
