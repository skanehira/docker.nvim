local view = require("docker.state.view")

describe("docker.state.view", function()
  describe("new", function()
    it("種別を持ち項目が空でカーソルが先頭の状態を作る", function()
      assert.are.same({ kind = "container", items = {}, cursor = 1 }, view.new("container"))
    end)
  end)

  describe("with_items", function()
    it("項目を差し替えた新しい状態を返す", function()
      local before = view.new("container")

      local after = view.with_items(before, { { id = "a" } })

      assert.are.same({ kind = "container", items = { { id = "a" } }, cursor = 1 }, after)
    end)

    it("元の状態を書き換えない", function()
      -- 状態を唯一の源として描画するため、更新は必ず新しい値を作る。
      local before = view.new("container")

      view.with_items(before, { { id = "a" } })

      assert.are.same({ kind = "container", items = {}, cursor = 1 }, before)
    end)

    it("渡した配列を後から変更しても状態の項目は変わらない", function()
      -- 呼び出し側の配列をそのまま抱えると、ストア側の更新でビュー状態が
      -- 黙って変わり、描画とカーソルの整合が取れなくなる。
      local items = { { id = "a" } }
      local state = view.with_items(view.new("container"), items)

      table.insert(items, { id = "injected" })
      items[1].id = "changed"

      assert.are.same({ { id = "a" } }, state.items)
    end)

    it("カーソル位置は保つ", function()
      local before = view.with_cursor(view.with_items(view.new("container"), { { id = "a" }, { id = "b" } }), 2)

      local after = view.with_items(before, { { id = "a" }, { id = "b" }, { id = "c" } })

      assert.are.equal(2, after.cursor)
    end)

    it("項目が減ってカーソルが範囲外になるときは最後の行に寄せる", function()
      local before = view.with_cursor(view.with_items(view.new("container"), { { id = "a" }, { id = "b" } }), 2)

      local after = view.with_items(before, { { id = "a" } })

      assert.are.equal(1, after.cursor)
    end)

    it("項目が0件になってもカーソルは1のままになる", function()
      local before = view.with_cursor(view.with_items(view.new("container"), { { id = "a" }, { id = "b" } }), 2)

      local after = view.with_items(before, {})

      assert.are.equal(1, after.cursor)
    end)
  end)

  describe("with_cursor", function()
    it("カーソル位置を変えた新しい状態を返す", function()
      local before = view.with_items(view.new("container"), { { id = "a" }, { id = "b" } })

      local after = view.with_cursor(before, 2)

      assert.are.equal(2, after.cursor)
      assert.are.equal(1, before.cursor)
    end)

    it("項目数を超える位置は最後の行に丸める", function()
      local before = view.with_items(view.new("container"), { { id = "a" }, { id = "b" } })

      assert.are.equal(2, view.with_cursor(before, 99).cursor)
    end)

    it("1より小さい位置は先頭に丸める", function()
      local before = view.with_items(view.new("container"), { { id = "a" } })

      assert.are.equal(1, view.with_cursor(before, 0).cursor)
    end)
  end)

  describe("selected", function()
    it("カーソル位置の項目を返す", function()
      local state = view.with_cursor(view.with_items(view.new("container"), { { id = "a" }, { id = "b" } }), 2)

      assert.are.same({ id = "b" }, view.selected(state))
    end)

    it("項目が0件のときはnilを返す", function()
      assert.is_nil(view.selected(view.new("container")))
    end)
  end)
end)
