--- Declarative definitions of the resource kinds.
---
--- Adding a kind must be completed by adding a definition to this file alone, so that per-kind
--- branching does not grow in the views and the handlers (registry pattern).
local fields = require("docker.resources.fields")
local format = require("docker.format")
local service_loader = require("docker.resources.service_loader")

local M = {}

---@class docker.ColumnDef
---@field header string
---@field value fun(item: table): string

---@class docker.ResourceDefinition
---@field kind string                    "container" | "image" | "volume" | "network" | "service"
---@field subcommand string              the argument passed to `:Docker` (for example "containers")
---@field view_type string               the view type used to look up keymaps (for example "container_list")
---@field display_name string
---@field empty_text string              the single line shown in the list when there are 0 items
---@field list_args? fun(): string[]     docker arguments to list items (omitted for kinds that have load)
---@field delete_args? fun(item: table): string[] docker arguments to delete (never force delete)
---@field item_args? fun(id: string): string[]    docker arguments to fetch just one item again
---@field load? fun(ctx: table, on_done: fun(result: table)) for kinds whose list a single docker command cannot express
---@field event_reload? boolean for kinds that fetch every item again instead of one on an event
--- (used when the identifier does not correspond to the ID in the event)
---@field id fun(item: table): string    extraction of the identifier
---@field columns docker.ColumnDef[]
---@field status_column integer|nil      the column position to highlight (1-based)
---@field status? fun(item: table): string|nil only for kinds that have a state column
---@field event_type string|nil          the correspondence with the Type of docker events

--- The fields fetched for the container list.
--- The compose labels are taken by naming the key through `.Label`. `Labels` must not be taken as
--- a whole and split (that misreads both on commas inside label values and on an attack that
--- plants a fake label in a value).
--- `.Size` is not referenced (it makes size computation run and increases the execution time).
local CONTAINER_FIELDS = {
  { key = "id", expr = ".ID" },
  { key = "name", expr = ".Names" },
  { key = "image", expr = ".Image" },
  { key = "state", expr = ".State" },
  { key = "status", expr = ".Status" },
  { key = "ports", expr = ".Ports" },
  { key = "command", expr = ".Command" },
  { key = "created_at", expr = ".CreatedAt" },
  { key = "compose_project", expr = format.label_expr("com.docker.compose.project") },
  { key = "compose_service", expr = format.label_expr("com.docker.compose.service") },
  { key = "compose_oneoff", expr = format.label_expr("com.docker.compose.oneoff") },
  -- The location of the compose file. When listing from outside the project, this is what the
  -- place to look up the definition and the place to run the lifecycle operations are derived
  -- from. It is not used for the list display.
  { key = "compose_working_dir", expr = format.label_expr("com.docker.compose.project.working_dir") },
}

local IMAGE_FIELDS = {
  { key = "id", expr = ".ID" },
  { key = "repository", expr = ".Repository" },
  { key = "tag", expr = ".Tag" },
  { key = "created_since", expr = ".CreatedSince" },
  { key = "size", expr = ".Size" },
}

local VOLUME_FIELDS = {
  { key = "name", expr = ".Name" },
  { key = "driver", expr = ".Driver" },
  { key = "mountpoint", expr = ".Mountpoint" },
}

local NETWORK_FIELDS = {
  { key = "id", expr = ".ID" },
  { key = "name", expr = ".Name" },
  { key = "driver", expr = ".Driver" },
  { key = "scope", expr = ".Scope" },
}

---@param key string
---@return fun(item: table): string
local function plain(key)
  return function(item)
    local value = item[key]
    return type(value) == "string" and value or ""
  end
end

-- Declared ahead of time. Since the `load` of the service references the container definition,
-- `definitions` has to be visible as a local while the table is being built.
---@type table<string, docker.ResourceDefinition>
local definitions
definitions = {
  container = {
    kind = "container",
    subcommand = "containers",
    view_type = "container_list",
    display_name = "Containers",
    empty_text = "コンテナがありません",
    -- `-a` is there so that stopped containers are included in the list too (BR-022).
    -- Without `--no-trunc` the ID is truncated to 12 characters and Command to 20.
    list_args = function()
      return { "ps", "-a", "--no-trunc", "--format", format.template(CONTAINER_FIELDS) }
    end,
    -- Fetch again only the one item that changed in the event. Lighter than fetching everything.
    item_args = function(id)
      return { "ps", "-a", "--no-trunc", "--filter", "id=" .. id, "--format", format.template(CONTAINER_FIELDS) }
    end,
    -- Force delete (-f) is not added. Let docker reject deleting a running container (BR-002).
    delete_args = function(item)
      return { "rm", tostring(item.id) }
    end,
    id = plain("id"),
    columns = {
      { header = "NAME", value = plain("name") },
      { header = "IMAGE", value = plain("image") },
      { header = "STATUS", value = plain("status") },
      { header = "PORTS", value = fields.ports },
      { header = "PROJECT", value = plain("compose_project") },
      { header = "SERVICE", value = plain("compose_service") },
    },
    status_column = 3,
    status = fields.state,
    event_type = "container",
  },
  image = {
    kind = "image",
    subcommand = "images",
    view_type = "image_list",
    display_name = "Images",
    empty_text = "イメージがありません",
    -- `docker image ls` cannot handle `.Label`, so there are no label-derived fields.
    -- Unlike for containers, `.Size` of an image is a default item of the list and costs nothing extra.
    list_args = function()
      return { "image", "ls", "--no-trunc", "--format", format.template(IMAGE_FIELDS) }
    end,
    -- The Actor.ID of the event is the sha of the image and does not correspond to our identifier
    -- (the tag reference). Since several tags can point at the same sha it cannot be expressed by
    -- fetching just one item again, so everything is fetched again.
    -- The image list can be drawn in a few milliseconds even with many items, so there is no real harm.
    event_reload = true,
    -- The same image can carry several tags. Deleting by ID targets the image itself, which cannot
    -- be deleted while another tag still uses it. If there is a tag, delete by the tag reference.
    delete_args = function(item)
      local repository = tostring(item.repository or "")
      local tag = tostring(item.tag or "")
      if repository ~= "" and repository ~= "<none>" and tag ~= "" and tag ~= "<none>" then
        return { "rmi", ("%s:%s"):format(repository, tag) }
      end
      return { "rmi", tostring(item.id) }
    end,
    -- Since the same image carries several tags, the ID would collapse separate rows into one item.
    -- The identifier is the unit the user sees and operates on (the tag reference).
    id = function(item)
      local repository = tostring(item.repository or "")
      local tag = tostring(item.tag or "")
      if repository ~= "" and repository ~= "<none>" and tag ~= "" and tag ~= "<none>" then
        return ("%s:%s"):format(repository, tag)
      end
      return tostring(item.id)
    end,
    columns = {
      { header = "REPOSITORY", value = plain("repository") },
      { header = "TAG", value = plain("tag") },
      { header = "SIZE", value = plain("size") },
      { header = "CREATED", value = plain("created_since") },
    },
    event_type = "image",
  },
  volume = {
    kind = "volume",
    subcommand = "volumes",
    view_type = "volume_list",
    display_name = "Volumes",
    empty_text = "ボリュームがありません",
    list_args = function()
      return { "volume", "ls", "--format", format.template(VOLUME_FIELDS) }
    end,
    item_args = function(id)
      return { "volume", "ls", "--filter", "name=" .. id, "--format", format.template(VOLUME_FIELDS) }
    end,
    delete_args = function(item)
      return { "volume", "rm", tostring(item.name) }
    end,
    -- For a volume the name is the identifier. In events the name is what goes into Actor.ID too.
    id = plain("name"),
    columns = {
      { header = "NAME", value = plain("name") },
      { header = "DRIVER", value = plain("driver") },
      { header = "MOUNTPOINT", value = plain("mountpoint") },
    },
    event_type = "volume",
  },
  network = {
    kind = "network",
    subcommand = "networks",
    view_type = "network_list",
    display_name = "Networks",
    empty_text = "ネットワークがありません",
    list_args = function()
      return { "network", "ls", "--no-trunc", "--format", format.template(NETWORK_FIELDS) }
    end,
    item_args = function(id)
      return { "network", "ls", "--no-trunc", "--filter", "id=" .. id, "--format", format.template(NETWORK_FIELDS) }
    end,
    -- docker rejects deleting the built-in networks (bridge / host / none).
    -- Do not reject it on our side; present docker's error as it is (BR-016).
    delete_args = function(item)
      return { "network", "rm", tostring(item.id) }
    end,
    id = plain("id"),
    columns = {
      { header = "NAME", value = plain("name") },
      { header = "DRIVER", value = plain("driver") },
      { header = "SCOPE", value = plain("scope") },
    },
    event_type = "network",
  },
  service = {
    kind = "service",
    subcommand = "services",
    view_type = "service_list",
    display_name = "Services",
    empty_text = "compose プロジェクトがありません",
    -- The service list cannot be obtained by a single docker command. service_loader assembles it.
    load = function(ctx, on_done)
      service_loader.load({ cwd = ctx.cwd, container_args = definitions.container.list_args() }, on_done)
    end,
    id = function(item)
      return ("%s/%s"):format(tostring(item.project), tostring(item.name))
    end,
    -- The list merges every project, so which project a row belongs to is placed first.
    columns = {
      { header = "PROJECT", value = plain("project") },
      { header = "SERVICE", value = plain("name") },
      { header = "STATUS", value = plain("status") },
      { header = "CONTAINER", value = plain("container") },
    },
    status_column = 3,
    status = plain("status"),
    -- The state of a service is determined by the state of its container, so it is updated on
    -- container events.
    event_type = "container",
  },
}

--- The order in which they are accepted as subcommands of `:Docker`. Add here when adding a definition.
local ORDER = { "container", "image", "volume", "network", "service" }

---@param kind string
---@return docker.ResourceDefinition|nil
function M.get(kind)
  return definitions[kind]
end

--- Look up a definition from the argument of `:Docker`.
---@param subcommand string
---@return docker.ResourceDefinition|nil
function M.by_subcommand(subcommand)
  for _, kind in ipairs(ORDER) do
    if definitions[kind].subcommand == subcommand then
      return definitions[kind]
    end
  end
  return nil
end

---@return string[] the list of `:Docker` subcommand names
function M.subcommands()
  local names = {}
  for _, kind in ipairs(ORDER) do
    table.insert(names, definitions[kind].subcommand)
  end
  return names
end

return M
