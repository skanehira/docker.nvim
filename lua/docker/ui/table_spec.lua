local tbl = require("docker.ui.table")

describe("docker.ui.table", function()
  describe("compute_widths", function()
    it("各列の最大幅に揃える", function()
      local widths = tbl.compute_widths({ "NAME", "IMAGE" }, {
        { "web", "alpine:3.20" },
        { "database", "postgres" },
      })

      assert.are.same({ 8, 11 }, widths)
    end)

    it("見出しの方が長い列は見出しの幅になる", function()
      local widths = tbl.compute_widths({ "SERVICE", "ID" }, { { "web", "abc" } })

      assert.are.same({ 7, 3 }, widths)
    end)

    it("行が1件も無いときは見出しの幅になる", function()
      assert.are.same({ 4, 5 }, tbl.compute_widths({ "NAME", "IMAGE" }, {}))
    end)

    it("全角文字は表示幅で数える", function()
      -- "日本語" はバイト長 9、表示幅 6。
      local widths = tbl.compute_widths({ "NAME" }, { { "日本語" } })

      assert.are.same({ 6 }, widths)
    end)

    it("空値の列は見出しの幅のままになる", function()
      local widths = tbl.compute_widths({ "PROJECT" }, { { "" }, { "" } })

      assert.are.same({ 7 }, widths)
    end)
  end)

  describe("format_row", function()
    it("各列を指定幅まで空白で埋めて連結する", function()
      assert.are.equal("web       alpine", tbl.format_row({ "web", "alpine" }, { 8, 6 }))
    end)

    it("末尾の余白は残さない", function()
      -- 行末に空白があるとカーソル移動と選択範囲が見た目とずれる。
      assert.are.equal("web       alpine", tbl.format_row({ "web", "alpine" }, { 8, 20 }))
    end)

    it("全角文字を含む列でも次の列の開始位置が揃う", function()
      local first = tbl.format_row({ "日本語", "x" }, { 8, 1 })
      local second = tbl.format_row({ "abcdef", "y" }, { 8, 1 })

      -- 1 列目は幅 8、区切りが 2 桁なので 2 列目はどちらも 10 桁目から始まる。
      assert.are.equal(vim.fn.strdisplaywidth(first), vim.fn.strdisplaywidth(second))
      assert.are.equal("日本語    x", first)
      assert.are.equal("abcdef    y", second)
    end)

    it("空値の列も幅の分だけ空けて次の列を揃える", function()
      -- 1 列目 8 + 区切り 2 + 2 列目 5 + 区切り 2 = 3 列目は 17 桁目から始まる。
      assert.are.equal("web              web", tbl.format_row({ "web", "", "web" }, { 8, 5, 3 }))
    end)

    it("指定幅より長い値は切り詰めずそのまま出す", function()
      -- 切り詰めると ID や名前が読めなくなる。桁ずれより情報の欠落を避ける。
      assert.are.equal("very-long-name  x", tbl.format_row({ "very-long-name", "x" }, { 4, 1 }))
    end)
  end)

  describe("column_span", function()
    it("先頭の列はバイト0から始まる", function()
      local from, to = tbl.column_span({ "web", "alpine" }, { 8, 6 }, 1)

      assert.are.equal(0, from)
      assert.are.equal(3, to)
    end)

    it("2列目は前の列の幅と区切りの分だけ後ろから始まる", function()
      local from, to = tbl.column_span({ "web", "alpine" }, { 8, 6 }, 2)

      assert.are.equal(10, from)
      assert.are.equal(16, to)
    end)

    it("全角文字を含む列の後ろでもバイト位置で返す", function()
      -- extmark はバイト位置を取るため、表示幅ではなくバイト数で返す必要がある。
      local line = tbl.format_row({ "日本語", "running" }, { 8, 7 })
      local from, to = tbl.column_span({ "日本語", "running" }, { 8, 7 }, 2)

      assert.are.equal("running", line:sub(from + 1, to))
    end)

    it("値が空の列は開始位置と終了位置が同じになる", function()
      local from, to = tbl.column_span({ "web", "" }, { 8, 5 }, 2)

      assert.are.equal(from, to)
    end)
  end)
end)
