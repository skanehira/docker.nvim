local tbl = require("docker.ui.table")

describe("docker.ui.table", function()
  describe("compute_widths", function()
    it("aligns each column to its widest value", function()
      local widths = tbl.compute_widths({ "NAME", "IMAGE" }, {
        { "web", "alpine:3.20" },
        { "database", "postgres" },
      })

      assert.are.same({ 8, 11 }, widths)
    end)

    it("uses the header width for a column whose header is the longest", function()
      local widths = tbl.compute_widths({ "SERVICE", "ID" }, { { "web", "abc" } })

      assert.are.same({ 7, 3 }, widths)
    end)

    it("uses the header width when there is not a single row", function()
      assert.are.same({ 4, 5 }, tbl.compute_widths({ "NAME", "IMAGE" }, {}))
    end)

    it("counts full-width characters by display width", function()
      -- "日本語" has a byte length of 9 and a display width of 6.
      local widths = tbl.compute_widths({ "NAME" }, { { "日本語" } })

      assert.are.same({ 6 }, widths)
    end)

    it("keeps a column of empty values at the header width", function()
      local widths = tbl.compute_widths({ "PROJECT" }, { { "" }, { "" } })

      assert.are.same({ 7 }, widths)
    end)
  end)

  describe("format_row", function()
    it("pads each column with spaces up to the given width and concatenates them", function()
      assert.are.equal("web       alpine", tbl.format_row({ "web", "alpine" }, { 8, 6 }))
    end)

    it("leaves no trailing padding", function()
      -- Whitespace at the end of a line makes cursor movement and the selection range
      -- disagree with what is displayed.
      assert.are.equal("web       alpine", tbl.format_row({ "web", "alpine" }, { 8, 20 }))
    end)

    it("lines up the start of the next column even for a column with full-width characters", function()
      local first = tbl.format_row({ "日本語", "x" }, { 8, 1 })
      local second = tbl.format_row({ "abcdef", "y" }, { 8, 1 })

      -- The first column is 8 wide and the separator is 2, so the second column starts at
      -- column 10 in both cases.
      assert.are.equal(vim.fn.strdisplaywidth(first), vim.fn.strdisplaywidth(second))
      assert.are.equal("日本語    x", first)
      assert.are.equal("abcdef    y", second)
    end)

    it("still leaves the full width for an empty column so the next column lines up", function()
      -- First column 8 + separator 2 + second column 5 + separator 2 = the third column starts at column 17.
      assert.are.equal("web              web", tbl.format_row({ "web", "", "web" }, { 8, 5, 3 }))
    end)

    it("emits a value longer than the given width as is instead of truncating it", function()
      -- Truncating would make IDs and names unreadable. Losing information is avoided over misalignment.
      assert.are.equal("very-long-name  x", tbl.format_row({ "very-long-name", "x" }, { 4, 1 }))
    end)
  end)

  describe("column_span", function()
    it("starts the first column at byte 0", function()
      local from, to = tbl.column_span({ "web", "alpine" }, { 8, 6 }, 1)

      assert.are.equal(0, from)
      assert.are.equal(3, to)
    end)

    it("starts the second column after the width of the previous column plus the separator", function()
      local from, to = tbl.column_span({ "web", "alpine" }, { 8, 6 }, 2)

      assert.are.equal(10, from)
      assert.are.equal(16, to)
    end)

    it("returns byte positions even after a column with full-width characters", function()
      -- extmarks take byte positions, so byte counts rather than display widths must be returned.
      local line = tbl.format_row({ "日本語", "running" }, { 8, 7 })
      local from, to = tbl.column_span({ "日本語", "running" }, { 8, 7 }, 2)

      assert.are.equal("running", line:sub(from + 1, to))
    end)

    it("returns the same start and end position for a column with an empty value", function()
      local from, to = tbl.column_span({ "web", "" }, { 8, 5 }, 2)

      assert.are.equal(from, to)
    end)
  end)
end)
