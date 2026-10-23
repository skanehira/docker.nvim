local config = require("docker.config")
local list = require("docker.views.list")
local registry = require("docker.resources.registry")

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
    config._reset()
    def = assert(registry.get("container"))
  end)

  after_each(function()
    config._reset()
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

      assert.are.equal(2, #built.lines, "the project header and the container row should be drawn")
      assert.are.equal("▾ projalpha", built.lines[1])
      assert.are.equal("  ctr        projalpha  svcbeta  img    Up", built.lines[2])
    end)

    it("leaves PROJECT and SERVICE blank for a container not managed by compose", function()
      local built = list.build(def, { container({ name = "plain" }) })

      assert.are.equal("plain  " .. string.rep(" ", 18) .. "alpine:3.20  Up 5 days", built.lines[1])
    end)

    describe("grouping by project", function()
      ---@return table[]
      local function grouped_items()
        return {
          container({ id = "1", name = "shop-web-1", compose_project = "shop", compose_service = "web" }),
          container({ id = "2", name = "blog-db-1", compose_project = "blog", compose_service = "db" }),
          container({ id = "3", name = "shop-db-1", compose_project = "shop", compose_service = "db" }),
          container({ id = "4", name = "plain" }),
        }
      end

      it("puts a header row before the containers of each project", function()
        local built = list.build(def, grouped_items())

        assert.are.equal(6, #built.lines, "2 project headers, 3 project containers and 1 ungrouped container")
        assert.is_truthy(built.lines[1]:find("▾ blog", 1, true), built.lines[1])
        assert.is_truthy(built.lines[2]:find("blog-db-1", 1, true), built.lines[2])
        assert.is_truthy(built.lines[3]:find("▾ shop", 1, true), built.lines[3])
        assert.is_truthy(built.lines[4]:find("shop-web-1", 1, true), built.lines[4])
        assert.is_truthy(built.lines[5]:find("shop-db-1", 1, true), built.lines[5])
        assert.is_truthy(built.lines[6]:find("plain", 1, true), built.lines[6])
      end)

      it("indents the containers under the project header", function()
        local built = list.build(def, {
          container({ id = "1", name = "shop-web-1", compose_project = "shop", compose_service = "web" }),
          container({ id = "2", name = "plain" }),
        })

        assert.are.equal("  ", built.lines[2]:sub(1, 2), "a project container should be indented")
        assert.are.equal("p", built.lines[3]:sub(1, 1), "an ungrouped container should not be indented")
      end)

      it("sorts the projects by name so that the order does not change between fetches", function()
        local reversed = {
          container({ id = "1", name = "z", compose_project = "zeta", compose_service = "s" }),
          container({ id = "2", name = "a", compose_project = "alpha", compose_service = "s" }),
        }

        local built = list.build(def, reversed)

        assert.is_truthy(built.lines[1]:find("▾ alpha", 1, true), built.lines[1])
        assert.is_truthy(built.lines[3]:find("▾ zeta", 1, true), built.lines[3])
      end)

      it("hides the containers of a folded project and marks the header as folded", function()
        local built = list.build(def, grouped_items(), { collapsed = { shop = true } })

        assert.are.equal(4, #built.lines, "the shop containers should be hidden")
        assert.is_truthy(built.lines[3]:find("▸ shop", 1, true), built.lines[3])
        assert.is_true(built.entries[3].collapsed)
        assert.are.same({ "shop-web-1", "shop-db-1" }, {
          built.entries[3].items[1].name,
          built.entries[3].items[2].name,
        })
      end)

      it("keeps the ungrouped containers after the grouped ones", function()
        local built = list.build(def, {
          container({ id = "1", name = "plain-before", compose_project = "" }),
          container({ id = "2", name = "grouped", compose_project = "shop", compose_service = "web" }),
          container({ id = "3", name = "plain-after", compose_project = "" }),
        })

        assert.is_truthy(built.lines[1]:find("▾ shop", 1, true), built.lines[1])
        assert.is_truthy(built.lines[2]:find("grouped", 1, true), built.lines[2])
        assert.is_truthy(built.lines[3]:find("plain-before", 1, true), built.lines[3])
        assert.is_truthy(built.lines[4]:find("plain-after", 1, true), built.lines[4])
      end)

      it("exposes each row as an entry so a header can be told apart from a resource", function()
        local entries = list.entries(def, grouped_items())

        assert.are.equal("blog", entries[1].group)
        assert.is_nil(entries[1].item)
        assert.are.equal("blog-db-1", entries[2].item.name)
        assert.is_nil(entries[2].group)
      end)

      it("shows the busy marker on the project header while a project operation runs", function()
        local built = list.build(def, grouped_items(), {
          busy = function(item)
            return item.id == "shop"
          end,
        })

        assert.is_truthy(built.lines[3]:find("(busy)", 1, true), built.lines[3])
        assert.is_nil(built.lines[1]:find("(busy)", 1, true), built.lines[1])
      end)
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

    describe("the column width limit", function()
      it("cuts an image name wider than the limit down to the limit", function()
        local built = list.build(def, { container({ name = "web", image = string.rep("a", 40), status = "Up" }) })

        -- The value held in rows is cut as well, so the widths and the highlight byte ranges
        -- are computed against what is actually displayed.
        assert.are.equal(string.rep("a", 29) .. "…", built.rows[1][4])
        assert.are.equal(30, built.widths[4])
        assert.are.equal("web   " .. string.rep(" ", 18) .. string.rep("a", 29) .. "…  Up", built.lines[1])
      end)

      it("leaves an image name that fits within the limit untouched", function()
        local built = list.build(def, { container({ name = "web", image = "alpine:3.20", status = "Up" }) })

        assert.are.equal("alpine:3.20", built.rows[1][4])
        assert.are.equal(11, built.widths[4])
      end)

      it("follows the limit configured by the user", function()
        config.setup({ column_max_widths = { container_list = { image = 10 } } })

        local built = list.build(def, { container({ name = "web", image = string.rep("a", 40), status = "Up" }) })

        assert.are.equal(string.rep("a", 9) .. "…", built.rows[1][4])
        assert.are.equal(10, built.widths[4])
        assert.are.equal("web   " .. string.rep(" ", 18) .. string.rep("a", 9) .. "…  Up", built.lines[1])
      end)

      it("shows the whole image name when the limit is removed", function()
        config.setup({ column_max_widths = { container_list = { image = false } } })

        local built = list.build(def, { container({ name = "web", image = string.rep("a", 40), status = "Up" }) })

        assert.are.equal(string.rep("a", 40), built.rows[1][4])
        assert.are.equal(40, built.widths[4])
      end)
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

  describe("entry_at", function()
    it("returns the row that corresponds to the cursor line", function()
      local entries = {
        { group = "shop", values = { "▾ shop" } },
        { item = container({ id = "1" }), values = {} },
      }

      assert.are.equal("shop", list.entry_at(entries, 1).group)
      assert.are.equal("1", list.entry_at(entries, 2).item.id)
    end)

    it("returns nil for a line beyond the rows", function()
      assert.is_nil(list.entry_at({ { group = "shop", values = {} } }, 2))
    end)

    it("returns nil for a line number of zero or less", function()
      assert.is_nil(list.entry_at({ { group = "shop", values = {} } }, 0))
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
        container({ id = "1", name = "web", compose_project = string.rep("p", 100) }),
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
      -- Compare display columns rather than byte offsets: the fold marker of a group header is
      -- a multi-byte character, so its byte position and display position differ.
      local headers = {}
      for _, column in ipairs(def.columns) do
        table.insert(headers, column.header)
      end
      local function display_start(values, widths, index)
        local column = 0
        for i = 1, index - 1 do
          local value = values[i] or ""
          local value_width = vim.fn.strdisplaywidth(value)
          column = column + value_width + math.max((widths[i] or 0) - value_width, 0) + 2
        end
        return column
      end
      local header_starts, row_starts = {}, {}
      for index = 1, #headers do
        table.insert(header_starts, display_start(headers, built.widths, index))
        table.insert(row_starts, display_start(built.rows[1], built.widths, index))
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

    it("highlights a group header row as a heading", function()
      local highlight = require("docker.ui.highlight")
      handle = window.open({ title = "Containers" })

      list.render(handle, def, {
        container({ name = "web", compose_project = "shop", compose_service = "web" }),
      })

      local marks = vim.api.nvim_buf_get_extmarks(handle.bufnr, highlight.namespace(), 0, -1, { details = true })
      local group_mark
      for _, mark in ipairs(marks) do
        if mark[2] == 0 then
          group_mark = mark
          break
        end
      end
      assert.is_truthy(group_mark, "the project header row should be highlighted")
      assert.are.equal("DockerGroup", group_mark[4].hl_group)
    end)

    it("keeps the status highlight on the right range for an indented child row", function()
      local highlight = require("docker.ui.highlight")
      handle = window.open({ title = "Containers" })

      list.render(handle, def, {
        container({
          name = "shop-web-1",
          compose_project = "shop",
          compose_service = "web",
          state = "running",
          status = "Up 2 hours",
        }),
      })

      local marks = vim.api.nvim_buf_get_extmarks(handle.bufnr, highlight.namespace(), 0, -1, { details = true })
      local status_mark
      for _, mark in ipairs(marks) do
        if mark[2] == 1 then
          status_mark = mark
          break
        end
      end
      assert.is_truthy(status_mark, "the STATUS column of the child row should be highlighted")
      local line = vim.api.nvim_buf_get_lines(handle.bufnr, 1, 2, false)[1]
      assert.are.equal("Up 2 hours", line:sub(status_mark[3] + 1, status_mark[4].end_col))
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
      assert.are.equal(3, #lines, "the project header and both items must be rendered")
      assert.is_truthy(lines[1]:find("▾ proj EVIL", 1, true), lines[1])
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
      -- The project header and its container row are drawn per project, so the PROJECT column
      -- starts at the same position in the two container rows.
      assert.are.equal(lines[2]:find("aa bb", 1, true), lines[4]:find("cccc", 1, true))
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
