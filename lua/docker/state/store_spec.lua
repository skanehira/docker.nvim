local store = require("docker.state.store")

describe("docker.state.store", function()
  before_each(function()
    store._reset()
  end)

  describe("replace_all", function()
    it("replaces the whole content of a kind with the result of a list fetch", function()
      store.replace_all("container", { { id = "a" }, { id = "b" } })
      store.replace_all("container", { { id = "c" } })

      assert.are.same({ { id = "c" } }, store.list("container"))
    end)

    it("does not affect the content of another kind", function()
      store.replace_all("container", { { id = "a" } })
      store.replace_all("image", { { id = "img" } })

      store.replace_all("container", {})

      assert.are.same({}, store.list("container"))
      assert.are.same({ { id = "img" } }, store.list("image"))
    end)

    it("keeps the order the items were fetched in", function()
      store.replace_all("container", { { id = "c" }, { id = "a" }, { id = "b" } })

      local ids = {}
      for _, item in ipairs(store.list("container")) do
        table.insert(ids, item.id)
      end
      assert.are.same({ "c", "a", "b" }, ids)
    end)
  end)

  describe("upsert", function()
    it("appends at the end when the ID is not registered yet", function()
      store.replace_all("container", { { id = "a" } })

      store.upsert("container", { id = "b", state = "running" })

      assert.are.same({ { id = "a" }, { id = "b", state = "running" } }, store.list("container"))
    end)

    it("replaces the content in place when the ID is already registered", function()
      store.replace_all("container", { { id = "a" }, { id = "b" }, { id = "c" } })

      store.upsert("container", { id = "b", state = "exited" })

      assert.are.same({ { id = "a" }, { id = "b", state = "exited" }, { id = "c" } }, store.list("container"))
    end)

    it("does not duplicate an item when the same ID is added repeatedly", function()
      -- INV-1: only one item with the same ID exists within one kind.
      store.upsert("container", { id = "a", state = "created" })
      store.upsert("container", { id = "a", state = "running" })
      store.upsert("container", { id = "a", state = "exited" })

      assert.are.same({ { id = "a", state = "exited" } }, store.list("container"))
    end)
  end)

  describe("remove", function()
    it("removes only the item with the given ID", function()
      store.replace_all("container", { { id = "a" }, { id = "b" }, { id = "c" } })

      store.remove("container", "b")

      assert.are.same({ { id = "a" }, { id = "c" } }, store.list("container"))
    end)

    it("leaves the content unchanged when a nonexistent ID is given", function()
      store.replace_all("container", { { id = "a" } })

      store.remove("container", "missing")

      assert.are.same({ { id = "a" } }, store.list("container"))
    end)
  end)

  describe("list", function()
    it("returns an empty table for a kind that has never been registered", function()
      assert.are.same({}, store.list("volume"))
    end)

    it("keeps the store content unchanged when the caller modifies the returned table", function()
      store.replace_all("container", { { id = "a" } })

      local listed = store.list("container")
      table.insert(listed, { id = "injected" })

      assert.are.same({ { id = "a" } }, store.list("container"))
    end)
  end)

  describe("subscribe", function()
    it("notifies subscribers of the kind that changed when the content changes", function()
      local notified = {}
      store.subscribe(function(kind)
        table.insert(notified, kind)
      end)

      store.replace_all("container", { { id = "a" } })
      store.upsert("image", { id = "img" })
      store.remove("container", "a")

      assert.are.same({ "container", "image", "container" }, notified)
    end)

    it("notifies each of them when there are several subscribers", function()
      local first, second = {}, {}
      store.subscribe(function(kind)
        table.insert(first, kind)
      end)
      store.subscribe(function(kind)
        table.insert(second, kind)
      end)

      store.replace_all("container", {})

      assert.are.same({ "container" }, first)
      assert.are.same({ "container" }, second)
    end)

    it("stops notifying from then on once the subscription is cancelled", function()
      local notified = {}
      local unsubscribe = store.subscribe(function(kind)
        table.insert(notified, kind)
      end)

      store.replace_all("container", {})
      unsubscribe()
      store.replace_all("container", {})

      assert.are.same({ "container" }, notified)
    end)

    it("keeps notifying the other subscribers after one cancels", function()
      local kept = {}
      local unsubscribe = store.subscribe(function() end)
      store.subscribe(function(kind)
        table.insert(kept, kind)
      end)

      unsubscribe()
      store.replace_all("image", {})

      assert.are.same({ "image" }, kept)
    end)

    it("does not notify when removing a nonexistent ID", function()
      -- Asking for a redraw when nothing changed makes the drawing spin idly on a daemon with many events.
      store.replace_all("container", { { id = "a" } })
      local notified = {}
      store.subscribe(function(kind)
        table.insert(notified, kind)
      end)

      store.remove("container", "missing")

      assert.are.same({}, notified)
    end)
  end)
end)
