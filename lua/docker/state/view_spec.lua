local view = require("docker.state.view")

describe("docker.state.view", function()
  describe("new", function()
    it("creates a state that has the kind, no items and the cursor at the top", function()
      assert.are.same(
        { kind = "container", items = {}, cursor = 1, filter = "", collapsed = {} },
        view.new("container")
      )
    end)
  end)

  describe("with_items", function()
    it("returns a new state with the items swapped", function()
      local before = view.new("container")

      local after = view.with_items(before, { { id = "a" } })

      assert.are.same({ kind = "container", items = { { id = "a" } }, cursor = 1, filter = "", collapsed = {} }, after)
    end)

    it("does not rewrite the original state", function()
      -- The drawing uses the state as the single source of truth, so an update always creates a new value.
      local before = view.new("container")

      view.with_items(before, { { id = "a" } })

      assert.are.same({ kind = "container", items = {}, cursor = 1, filter = "", collapsed = {} }, before)
    end)

    it("keeps the items of the state unchanged when the passed array is modified afterwards", function()
      -- Holding on to the caller's array would make the view state change silently on a store
      -- update, putting the drawing and the cursor out of sync.
      local items = { { id = "a" } }
      local state = view.with_items(view.new("container"), items)

      table.insert(items, { id = "injected" })
      items[1].id = "changed"

      assert.are.same({ { id = "a" } }, state.items)
    end)

    it("keeps the cursor position", function()
      local before = view.with_cursor(view.with_items(view.new("container"), { { id = "a" }, { id = "b" } }), 2)

      local after = view.with_items(before, { { id = "a" }, { id = "b" }, { id = "c" } })

      assert.are.equal(2, after.cursor)
    end)

    it("moves the cursor to the last line when the items shrink and it falls out of range", function()
      local before = view.with_cursor(view.with_items(view.new("container"), { { id = "a" }, { id = "b" } }), 2)

      local after = view.with_items(before, { { id = "a" } })

      assert.are.equal(1, after.cursor)
    end)

    it("keeps the cursor at 1 even when the items become 0", function()
      local before = view.with_cursor(view.with_items(view.new("container"), { { id = "a" }, { id = "b" } }), 2)

      local after = view.with_items(before, {})

      assert.are.equal(1, after.cursor)
    end)
  end)

  describe("with_cursor", function()
    it("returns a new state with the cursor position changed", function()
      local before = view.with_items(view.new("container"), { { id = "a" }, { id = "b" } })

      local after = view.with_cursor(before, 2)

      assert.are.equal(2, after.cursor)
      assert.are.equal(1, before.cursor)
    end)

    it("clamps a position beyond the number of items to the last line", function()
      local before = view.with_items(view.new("container"), { { id = "a" }, { id = "b" } })

      assert.are.equal(2, view.with_cursor(before, 99).cursor)
    end)

    it("clamps a position smaller than 1 to the top", function()
      local before = view.with_items(view.new("container"), { { id = "a" } })

      assert.are.equal(1, view.with_cursor(before, 0).cursor)
    end)
  end)

  describe("selected", function()
    it("returns the item at the cursor position", function()
      local state = view.with_cursor(view.with_items(view.new("container"), { { id = "a" }, { id = "b" } }), 2)

      assert.are.same({ id = "b" }, view.selected(state))
    end)

    it("returns nil when there are 0 items", function()
      assert.is_nil(view.selected(view.new("container")))
    end)
  end)

  describe("collapsed groups", function()
    it("starts with every group expanded", function()
      local state = view.new("container")

      assert.are.same({}, state.collapsed)
      assert.is_false(view.is_collapsed(state, "shop"))
    end)

    it("toggles a group without changing the other state", function()
      local before = view.with_items(view.new("container"), { { id = "a" } })

      local after = view.toggle_collapsed(before, "shop")

      assert.is_true(view.is_collapsed(after, "shop"))
      assert.are.same({ shop = true }, after.collapsed)
      assert.are.same({}, before.collapsed)
      assert.are.same(before.items, after.items)
    end)

    it("expands a group again when toggled twice", function()
      local state = view.toggle_collapsed(view.toggle_collapsed(view.new("container"), "shop"), "shop")

      assert.is_false(view.is_collapsed(state, "shop"))
      assert.are.same({}, state.collapsed)
    end)

    it("keeps the folded groups when the items are swapped", function()
      local state = view.toggle_collapsed(view.new("container"), "shop")

      assert.is_true(view.is_collapsed(view.with_items(state, { { id = "a" } }), "shop"))
    end)

    it("keeps the folded groups when the filter changes", function()
      local state = view.toggle_collapsed(view.new("container"), "shop")

      assert.is_true(view.is_collapsed(view.with_filter(state, "web"), "shop"))
    end)

    it("does not share the folded table with the state passed in", function()
      local collapsed = { shop = true }
      local state = view.with_collapsed(view.new("container"), collapsed)

      collapsed.blog = true

      assert.are.same({ shop = true }, state.collapsed)
    end)
  end)

  describe("filtering", function()
    local registry = require("docker.resources.registry")
    local def = assert(registry.get("container"))

    ---@param overrides table
    local function container(overrides)
      return vim.tbl_extend("force", {
        id = "id",
        name = "web",
        image = "alpine",
        state = "running",
        status = "Up",
        ports = "",
        command = "x",
        created_at = "now",
        compose_project = "",
        compose_service = "",
        compose_oneoff = "",
      }, overrides)
    end

    local function with(items)
      return view.with_items(view.new("container"), items)
    end

    it("returns every item when the filter is empty", function()
      local state = with({ container({ id = "1" }), container({ id = "2" }) })

      assert.are.equal(2, #view.visible_items(state, def))
    end)

    it("returns only the rows that partially match a displayed value", function()
      local state = with({
        container({ id = "1", name = "web-server" }),
        container({ id = "2", name = "database" }),
      })

      local visible = view.visible_items(view.with_filter(state, "web"), def)

      assert.are.equal(1, #visible)
      assert.are.equal("web-server", visible[1].name)
    end)

    it("does not distinguish upper case from lower case", function()
      local state = with({ container({ name = "WebServer" }) })

      assert.are.equal(1, #view.visible_items(view.with_filter(state, "webserver"), def))
    end)

    it("matches columns other than the name too", function()
      local state = with({ container({ name = "a", image = "postgres:16" }) })

      assert.are.equal(1, #view.visible_items(view.with_filter(state, "postgres"), def))
    end)

    it("returns 0 items when nothing matches", function()
      local state = with({ container({ name = "web" }) })

      assert.are.same({}, view.visible_items(view.with_filter(state, "zzz"), def))
    end)

    it("goes back to every row when the filter is cleared", function()
      local state = with({ container({ id = "1", name = "web" }), container({ id = "2", name = "db" }) })
      local filtered = view.with_filter(state, "web")

      local cleared = view.with_filter(filtered, "")

      assert.are.equal(2, #view.visible_items(cleared, def))
    end)

    it("moves the cursor back to the top when the filter changes", function()
      -- The correspondence between rows and items changes, so keeping the position would point at
      -- a different target.
      local state = view.with_cursor(with({ container({ id = "1" }), container({ id = "2" }) }), 2)

      assert.are.equal(1, view.with_filter(state, "web").cursor)
    end)

    it("keeps the filter when the items are swapped", function()
      local state = view.with_filter(with({ container({ name = "web" }) }), "web")

      assert.are.equal("web", view.with_items(state, { container({ name = "web" }) }).filter)
    end)
  end)
end)
