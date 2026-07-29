local store = require("docker.state.store")

describe("docker.state.store", function()
  before_each(function()
    store._reset()
  end)

  describe("replace_all", function()
    it("一覧取得の結果で種別ごとの内容を丸ごと置き換える", function()
      store.replace_all("container", { { id = "a" }, { id = "b" } })
      store.replace_all("container", { { id = "c" } })

      assert.are.same({ { id = "c" } }, store.list("container"))
    end)

    it("別の種別の内容には影響しない", function()
      store.replace_all("container", { { id = "a" } })
      store.replace_all("image", { { id = "img" } })

      store.replace_all("container", {})

      assert.are.same({}, store.list("container"))
      assert.are.same({ { id = "img" } }, store.list("image"))
    end)

    it("取得順を保って並べる", function()
      store.replace_all("container", { { id = "c" }, { id = "a" }, { id = "b" } })

      local ids = {}
      for _, item in ipairs(store.list("container")) do
        table.insert(ids, item.id)
      end
      assert.are.same({ "c", "a", "b" }, ids)
    end)
  end)

  describe("upsert", function()
    it("未登録のIDなら末尾に追加する", function()
      store.replace_all("container", { { id = "a" } })

      store.upsert("container", { id = "b", state = "running" })

      assert.are.same({ { id = "a" }, { id = "b", state = "running" } }, store.list("container"))
    end)

    it("登録済みのIDなら位置を保ったまま内容を置き換える", function()
      store.replace_all("container", { { id = "a" }, { id = "b" }, { id = "c" } })

      store.upsert("container", { id = "b", state = "exited" })

      assert.are.same({ { id = "a" }, { id = "b", state = "exited" }, { id = "c" } }, store.list("container"))
    end)

    it("同じIDを繰り返し追加しても重複しない", function()
      -- INV-1: 同一種別に同一 ID は 1 件しか存在しない。
      store.upsert("container", { id = "a", state = "created" })
      store.upsert("container", { id = "a", state = "running" })
      store.upsert("container", { id = "a", state = "exited" })

      assert.are.same({ { id = "a", state = "exited" } }, store.list("container"))
    end)
  end)

  describe("remove", function()
    it("指定したIDの要素だけを取り除く", function()
      store.replace_all("container", { { id = "a" }, { id = "b" }, { id = "c" } })

      store.remove("container", "b")

      assert.are.same({ { id = "a" }, { id = "c" } }, store.list("container"))
    end)

    it("存在しないIDを指定しても内容は変わらない", function()
      store.replace_all("container", { { id = "a" } })

      store.remove("container", "missing")

      assert.are.same({ { id = "a" } }, store.list("container"))
    end)
  end)

  describe("list", function()
    it("一度も登録されていない種別は空のテーブルを返す", function()
      assert.are.same({}, store.list("volume"))
    end)

    it("返したテーブルを呼び出し側が変更してもストアの内容は変わらない", function()
      store.replace_all("container", { { id = "a" } })

      local listed = store.list("container")
      table.insert(listed, { id = "injected" })

      assert.are.same({ { id = "a" } }, store.list("container"))
    end)
  end)

  describe("subscribe", function()
    it("内容が変わると購読者に変化した種別が通知される", function()
      local notified = {}
      store.subscribe(function(kind)
        table.insert(notified, kind)
      end)

      store.replace_all("container", { { id = "a" } })
      store.upsert("image", { id = "img" })
      store.remove("container", "a")

      assert.are.same({ "container", "image", "container" }, notified)
    end)

    it("購読者が複数いるとそれぞれに通知される", function()
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

    it("購読を解除するとそれ以降は通知されない", function()
      local notified = {}
      local unsubscribe = store.subscribe(function(kind)
        table.insert(notified, kind)
      end)

      store.replace_all("container", {})
      unsubscribe()
      store.replace_all("container", {})

      assert.are.same({ "container" }, notified)
    end)

    it("解除しても他の購読者には通知が続く", function()
      local kept = {}
      local unsubscribe = store.subscribe(function() end)
      store.subscribe(function(kind)
        table.insert(kept, kind)
      end)

      unsubscribe()
      store.replace_all("image", {})

      assert.are.same({ "image" }, kept)
    end)

    it("存在しないIDの削除では通知しない", function()
      -- 変化していないのに再描画を要求すると、イベントの多いデーモンで描画が空回りする。
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
