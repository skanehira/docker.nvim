local highlight = require("docker.ui.highlight")

describe("docker.ui.highlight", function()
  describe("group_for", function()
    it("状態ごとに対応するハイライトグループを返す", function()
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

    it("未知の状態は既定のグループになる", function()
      assert.are.equal("DockerStatusUnknown", highlight.group_for("something-new"))
    end)

    it("状態が無いときも既定のグループになる", function()
      assert.are.equal("DockerStatusUnknown", highlight.group_for(nil))
    end)

    it("大文字小文字の違いを吸収する", function()
      assert.are.equal("DockerStatusRunning", highlight.group_for("Running"))
    end)
  end)

  describe("setup", function()
    it("状態ごとのハイライトグループを定義する", function()
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
      }) do
        assert.is_truthy(vim.fn.hlexists(group) == 1, group .. " が定義されていること")
      end
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

    it("指定した行と範囲にハイライトを付ける", function()
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

    it("clearを呼ぶと付けたハイライトが消える", function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "web       running" })
      highlight.apply(bufnr, 0, 10, 17, "DockerStatusRunning")

      highlight.clear(bufnr)

      assert.are.same({}, marks())
    end)

    it("範囲が空のときはハイライトを付けない", function()
      -- 値が空の列に長さ 0 の extmark を置いても意味が無い。
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "web" })

      highlight.apply(bufnr, 0, 3, 3, "DockerStatusRunning")

      assert.are.same({}, marks())
    end)
  end)
end)
