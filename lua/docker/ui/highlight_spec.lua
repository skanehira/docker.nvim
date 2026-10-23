local highlight = require("docker.ui.highlight")

describe("docker.ui.highlight", function()
  after_each(function()
    -- Do not carry over colors that were defined directly in a test.
    for _, group in ipairs({ "DockerHeader", "DockerStatusRunning", "DockerGroup" }) do
      vim.api.nvim_set_hl(0, group, {})
    end
  end)

  describe("group_for", function()
    it("returns the highlight group that corresponds to each state", function()
      local actual = {}
      for _, state in ipairs({ "running", "exited", "paused", "created", "restarting", "dead", "none" }) do
        actual[state] = highlight.group_for(state)
      end

      assert.are.same({
        running = "DockerStatusRunning",
        exited = "DockerStatusExited",
        paused = "DockerStatusPaused",
        created = "DockerStatusCreated",
        restarting = "DockerStatusRestarting",
        dead = "DockerStatusDead",
        none = "DockerStatusNone",
      }, actual)
    end)

    it("falls back to the default group for an unknown state", function()
      assert.are.equal("DockerStatusUnknown", highlight.group_for("something-new"))
    end)

    it("falls back to the default group when there is no state", function()
      assert.are.equal("DockerStatusUnknown", highlight.group_for(nil))
    end)

    it("absorbs differences in letter case", function()
      assert.are.equal("DockerStatusRunning", highlight.group_for("Running"))
    end)
  end)

  describe("group_row_group", function()
    it("returns the group header highlight name", function()
      assert.are.equal("DockerGroup", highlight.group_row_group())
    end)
  end)

  describe("setup", function()
    it("defines a highlight group for each state", function()
      highlight.setup()

      for _, group in ipairs({
        "DockerStatusRunning",
        "DockerStatusExited",
        "DockerStatusPaused",
        "DockerStatusCreated",
        "DockerStatusRestarting",
        "DockerStatusDead",
        "DockerStatusNone",
        "DockerStatusUnknown",
        "DockerGroup",
      }) do
        assert.is_truthy(vim.fn.hlexists(group) == 1, group .. " must be defined")
      end
    end)

    it("defines the color of the header", function()
      -- Unlike the state groups, the header uses the colors of denops-docker.vim as they are.
      highlight.setup()

      assert.are.same(
        { fg = tonumber("e2a478", 16), ctermfg = 216, default = true },
        vim.api.nvim_get_hl(0, { name = "DockerHeader" })
      )
    end)

    it("does not overwrite colors the user has defined beforehand", function()
      -- The header specifies its color directly while the states are defined by link, so both are checked.
      vim.api.nvim_set_hl(0, "DockerHeader", { fg = "#123456" })
      vim.api.nvim_set_hl(0, "DockerStatusRunning", { fg = "#654321" })

      highlight.setup()

      assert.are.same({
        DockerHeader = { fg = tonumber("123456", 16) },
        DockerStatusRunning = { fg = tonumber("654321", 16) },
      }, {
        DockerHeader = vim.api.nvim_get_hl(0, { name = "DockerHeader" }),
        DockerStatusRunning = vim.api.nvim_get_hl(0, { name = "DockerStatusRunning" }),
      })
    end)
  end)

  describe("apply", function()
    local bufnr

    before_each(function()
      bufnr = vim.api.nvim_create_buf(false, true)
    end)

    after_each(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    ---@return table[]
    local function marks()
      return vim.api.nvim_buf_get_extmarks(bufnr, highlight.namespace(), 0, -1, { details = true })
    end

    it("applies the highlight to the given line and range", function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "web       running" })

      highlight.apply(bufnr, 0, 10, 17, "DockerStatusRunning")

      local got = marks()
      assert.are.equal(1, #got)
      local row, col, details = got[1][2], got[1][3], got[1][4]
      assert.are.equal(0, row)
      assert.are.equal(10, col)
      assert.are.equal(17, details.end_col)
      assert.are.equal("DockerStatusRunning", details.hl_group)
    end)

    it("removes the applied highlight when clear is called", function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "web       running" })
      highlight.apply(bufnr, 0, 10, 17, "DockerStatusRunning")

      highlight.clear(bufnr)

      assert.are.same({}, marks())
    end)

    it("applies no highlight when the range is empty", function()
      -- Placing a zero-length extmark on a column with an empty value carries no meaning.
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "web" })

      highlight.apply(bufnr, 0, 3, 3, "DockerStatusRunning")

      assert.are.same({}, marks())
    end)
  end)
end)
