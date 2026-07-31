local list = require("docker.views.list")
local registry = require("docker.resources.registry")
local tbl = require("docker.ui.table")

--- Raw container data as returned by listing. Only the given fields are overridden.
---@param overrides table|nil
---@return table
local function container(overrides)
  return vim.tbl_extend("force", {
    id = "abc123",
    name = "web",
    image = "alpine:3.20",
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

describe("docker.views.list", function()
  ---@type docker.ResourceDefinition
  local def

  before_each(function()
    def = assert(registry.get("container"))
  end)

  describe("build", function()
    it("puts the header into the winbar instead of a buffer line", function()
      -- Keeping the header out of the buffer makes the cursor line and the data row index map one to one.
      local built = list.build(def, { container() })

      assert.are.equal(1, #built.lines)
      assert.is_truthy(built.winbar:find("NAME", 1, true))
      assert.is_truthy(built.winbar:find("STATUS", 1, true))
    end)

    it("generates one buffer line per resource", function()
      local built = list.build(def, {
        container({ id = "1", name = "web" }),
        container({ id = "2", name = "db" }),
        container({ id = "3", name = "cache" }),
      })

      assert.are.equal(3, #built.lines)
    end)

    it("shows the PROJECT and SERVICE values in the row of a compose-managed container", function()
      -- The name, the project name and the service name are all made different from each other.
      -- Matching on a word contained in the container name would let the test pass with empty columns.
      local built = list.build(def, {
        container({
          name = "ctr",
          image = "img",
          status = "Up",
          compose_project = "projalpha",
          compose_service = "svcbeta",
          compose_oneoff = "False",
        }),
      })

      -- The column widths are determined by the length of the headers (NAME/IMAGE/STATUS/PORTS/PROJECT/SERVICE).
      -- PORTS is empty, so the gap between STATUS and PROJECT spans that width.
      assert.are.equal("ctr   img    Up             projalpha  svcbeta", built.lines[1])
    end)

    it("leaves PROJECT and SERVICE blank for a container not managed by compose", function()
      local built = list.build(def, { container({ name = "plain" }) })

      -- No trailing padding is left, so when the compose columns are empty the row ends before SERVICE.
      assert.are.equal("plain  alpine:3.20  Up 5 days", built.lines[1])
    end)

    it("emits a single line stating that there are no items when the list is empty", function()
      local built = list.build(def, {})

      assert.are.same({ "No containers" }, built.lines)
    end)

    it("still emits the header when the list is empty", function()
      local built = list.build(def, {})

      assert.is_truthy(built.winbar:find("NAME", 1, true))
    end)

    it("aligns each column to the widest value across the rows", function()
      local built = list.build(def, {
        container({ id = "1", name = "web" }),
        container({ id = "2", name = "very-long-container-name" }),
      })

      -- The IMAGE column starts at the same position in both rows.
      local first = built.lines[1]:find("alpine", 1, true)
      local second = built.lines[2]:find("alpine", 1, true)
      assert.are.equal(first, second)
    end)
  end)

  describe("item_at", function()
    it("returns the resource that corresponds to the cursor line", function()
      local items = { container({ id = "1" }), container({ id = "2" }), container({ id = "3" }) }

      assert.are.equal("2", list.item_at(items, 2).id)
    end)

    it("returns nil for any line when there are no items", function()
      assert.is_nil(list.item_at({}, 1))
    end)

    it("returns nil for a line beyond the number of items", function()
      assert.is_nil(list.item_at({ container() }, 2))
    end)

    it("returns nil for a line number of zero or less", function()
      assert.is_nil(list.item_at({ container() }, 0))
    end)
  end)

  describe("render", function()
    local window = require("docker.ui.window")
    local handle

    after_each(function()
      if handle then
        window.close(handle)
        handle = nil
      end
    end)

    it("keeps the header and the body in the same columns even when a row is too long to fit", function()
      -- When the text does not fit, the winbar drops its head by default, so only the header shifts left.
      handle = window.open({ title = "Containers", wrap = false })

      local built = list.render(handle, def, {
        container({ id = "1", name = "web", ports = string.rep("0.0.0.0:5001->5000/tcp, ", 8) }),
      })

      -- The header shown on screen must match the head of the header laid out at the same width as the rows.
      -- The last column is taken up by the truncation marker.
      local width = vim.api.nvim_win_get_width(handle.winid)
      local rendered = vim.api.nvim_eval_statusline(vim.wo[handle.winid].winbar, {
        winid = handle.winid,
        maxwidth = width,
        use_winbar = true,
      }).str
      assert.are.equal(built.winbar:sub(1, width - 1) .. ">", rendered)

      -- For every column, the start position of the header and of the body must line up.
      local headers = {}
      for _, column in ipairs(def.columns) do
        table.insert(headers, column.header)
      end
      local header_starts, row_starts = {}, {}
      for index = 1, #headers do
        table.insert(header_starts, (tbl.column_span(headers, built.widths, index)))
        table.insert(row_starts, (tbl.column_span(built.rows[1], built.widths, index)))
      end
      assert.are.same(header_starts, row_starts)
    end)

    it("reflects the rows and the header in the window", function()
      handle = window.open({ title = "Containers" })

      list.render(handle, def, { container({ name = "web" }), container({ name = "db" }) })

      local lines = vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)
      assert.are.equal(2, #lines)
      assert.is_truthy(lines[1]:find("web", 1, true))
      assert.is_truthy(vim.wo[handle.winid].winbar:find("NAME", 1, true))
    end)

    it("leaves none of the previous content behind on re-render", function()
      handle = window.open({ title = "Containers" })
      list.render(handle, def, { container({ name = "web" }), container({ name = "db" }) })

      list.render(handle, def, { container({ name = "cache" }) })

      assert.are.equal(1, #vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false))
    end)
  end)

  describe("safety of the rendered lines", function()
    local window = require("docker.ui.window")

    it("still renders the whole list when a value contains a newline", function()
      -- compose label values may contain any character. Even a single value containing a
      -- newline makes nvim_buf_set_lines fail, so the list itself cannot be shown.
      local handle = window.open({ title = "Containers" })

      list.render(handle, def, {
        container({ id = "1", name = "plain" }),
        container({ id = "2", name = "evil", compose_project = "proj\nEVIL" }),
      })

      local lines = vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)
      assert.are.equal(2, #lines, "both items must be rendered")
      assert.is_truthy(lines[2]:find("proj EVIL", 1, true), lines[2])
      window.close(handle)
    end)

    it("fits a value containing a carriage return or a tab into a single line", function()
      local handle = window.open({ title = "Containers" })

      list.render(handle, def, { container({ name = "a\tb\rc" }) })

      local lines = vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)
      assert.are.equal(1, #lines)
      assert.is_nil(lines[1]:find("\t", 1, true))
      window.close(handle)
    end)

    it("keeps the column alignment intact for a value containing a newline", function()
      local handle = window.open({ title = "Containers" })

      list.render(handle, def, {
        container({ id = "1", name = "one", compose_project = "aa\nbb" }),
        container({ id = "2", name = "two", compose_project = "cccc" }),
      })

      local lines = vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)
      assert.are.equal(lines[1]:find("aa bb", 1, true), lines[2]:find("cccc", 1, true))
      window.close(handle)
    end)

    it("does not error when rendering into a closed window", function()
      -- If the view is closed while fetching, the buffer is already invalid when the result arrives.
      local handle = window.open({ title = "Containers" })
      window.close(handle)

      list.render(handle, def, { container() })
    end)
  end)

  describe("rendering of each resource kind", function()
    -- The verification steps of G6 require list_spec to cover that the list of each kind is rendered.
    local samples = {
      image = { id = "i1", repository = "alpine", tag = "3.20", size = "5MB", created_since = "2 days ago" },
      volume = { name = "v1", driver = "local", mountpoint = "/var/lib/docker/volumes/v1" },
      network = { id = "n1", name = "bridge", driver = "bridge", scope = "local" },
      service = { project = "shop", name = "web", container = "shop-web-1", container_id = "c1", status = "running" },
    }

    it("generates a header and a row for every kind", function()
      local expected = {
        image = { "REPOSITORY  TAG   SIZE  CREATED", "alpine      3.20  5MB   2 days ago" },
        volume = { "NAME  DRIVER  MOUNTPOINT", "v1    local   /var/lib/docker/volumes/v1" },
        network = { "NAME    DRIVER  SCOPE", "bridge  bridge  local" },
        service = { "PROJECT  SERVICE  STATUS   CONTAINER", "shop     web      running  shop-web-1" },
      }

      local actual = {}
      for kind, item in pairs(samples) do
        local built = list.build(assert(registry.get(kind)), { item })
        actual[kind] = { built.winbar, built.lines[1] }
      end

      assert.are.same(expected, actual)
    end)

    it("emits the kind-specific empty message when there are no items", function()
      local actual = {}
      for kind in pairs(samples) do
        actual[kind] = list.build(assert(registry.get(kind)), {}).lines
      end

      assert.are.same({
        image = { "No images" },
        volume = { "No volumes" },
        network = { "No networks" },
        service = { "No compose projects" },
      }, actual)
    end)
  end)
end)
