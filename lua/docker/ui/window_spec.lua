local window = require("docker.ui.window")

describe("docker.ui.window", function()
  local opened

  before_each(function()
    opened = {}
  end)

  after_each(function()
    for _, handle in ipairs(opened) do
      window.close(handle)
    end
  end)

  ---@return docker.Window
  local function open(opts)
    local handle = window.open(vim.tbl_extend("force", { title = "Containers" }, opts or {}))
    table.insert(opened, handle)
    return handle
  end

  --- The winbar as it actually appears on screen. The raw option value contains the
  --- truncation format, so the rendered result is what gets checked.
  ---@param handle docker.Window
  ---@return string
  local function rendered_winbar(handle)
    return vim.api.nvim_eval_statusline(vim.wo[handle.winid].winbar, {
      winid = handle.winid,
      maxwidth = vim.api.nvim_win_get_width(handle.winid),
      use_winbar = true,
    }).str
  end

  --- The highlights applied to the winbar. `groups` was added in Neovim 0.11, so the
  --- comparison is narrowed to the fields that can be obtained on 0.10 as well.
  ---@param handle docker.Window
  ---@return { start: integer, group: string }[]
  local function applied_highlights(handle)
    local rendered = vim.api.nvim_eval_statusline(vim.wo[handle.winid].winbar, {
      winid = handle.winid,
      maxwidth = vim.api.nvim_win_get_width(handle.winid),
      use_winbar = true,
      highlights = true,
    })
    local applied = {}
    for _, item in ipairs(rendered.highlights) do
      table.insert(applied, { start = item.start, group = item.group })
    end
    return applied
  end

  --- Narrow the window to create a situation where the header overflows.
  ---@param handle docker.Window
  ---@param width integer
  local function narrow(handle, width)
    local config = vim.api.nvim_win_get_config(handle.winid)
    config.width = width
    vim.api.nvim_win_set_config(handle.winid, config)
  end

  describe("open", function()
    it("opens a float window positioned relative to the editor", function()
      local handle = open()

      local config = vim.api.nvim_win_get_config(handle.winid)
      assert.are.equal("editor", config.relative)
    end)

    it("has a border and a title", function()
      local handle = open({ title = "Containers" })

      local config = vim.api.nvim_win_get_config(handle.winid)
      assert.is_truthy(config.border, "border must be set")
      -- title is returned in the shape { { text, hl } }.
      assert.are.equal("Containers", config.title[1][1])
    end)

    it("lets the caller choose whether lines wrap", function()
      -- If the list wrapped, the buffer lines and the screen lines would diverge and the
      -- header would no longer line up with the columns.
      local wrapped = open({ title = "Wrapped" })
      local clipped = open({ title = "Clipped", wrap = false })

      assert.are.same({ true, false }, { vim.wo[wrapped.winid].wrap, vim.wo[clipped.winid].wrap })
    end)

    it("configures the buffer so that it is not a write target", function()
      local handle = open()

      assert.are.equal("nofile", vim.bo[handle.bufnr].buftype)
      assert.is_false(vim.bo[handle.bufnr].modifiable)
      assert.is_false(vim.bo[handle.bufnr].swapfile)
    end)

    it("lets the caller specify the stacking height", function()
      local lower = open({ zindex = 40 })
      local upper = open({ zindex = 60 })

      assert.are.equal(40, vim.api.nvim_win_get_config(lower.winid).zindex)
      assert.are.equal(60, vim.api.nvim_win_get_config(upper.winid).zindex)
    end)

    it("matches the body and border background to the editor while keeping the minimal settings", function()
      -- Left at the defaults, the body is painted with the NormalFloat background and only
      -- the winbar looks transparent. Moving the background to Normal makes the whole float
      -- consistent.
      -- At the same time, the EndOfBuffer cancellation that style="minimal" adds is not dropped.
      -- Overwriting it would make everything below the data rows a different color under color
      -- schemes that give EndOfBuffer a background color.
      local handle = open()

      -- Unfolded into a mapping so that the comparison does not depend on the order.
      local winhighlight = vim.wo[handle.winid].winhighlight
      local mapping = {}
      for pair in winhighlight:gmatch("[^,]+") do
        local from, to = pair:match("^([^:]*):(.*)$")
        mapping[from] = to
      end
      assert.are.same({ EndOfBuffer = "", NormalFloat = "Normal", FloatBorder = "Normal" }, mapping)

      -- Appending it wrongly would insert the same setting twice, which the mapping would hide.
      local _, occurrences = winhighlight:gsub("NormalFloat:", "")
      assert.are.equal(1, occurrences, winhighlight)
    end)

    it("places the window at the center of the editor", function()
      local handle = open()

      local config = vim.api.nvim_win_get_config(handle.winid)
      assert.are.equal(math.floor((vim.o.columns - config.width) / 2), config.col)
    end)
  end)

  describe("set_winbar", function()
    local HEADER = "NAME  IMAGE  STATUS  PORTS  PROJECT  SERVICE"

    before_each(function()
      -- In production the header highlight is defined by lifecycle.
      require("docker.ui.highlight").setup()
    end)

    it("drops the tail when the header overflows", function()
      -- By default the head is dropped and a `<` is prepended. The body is clipped at the
      -- right edge, so only the header would shift left and the columns would stop lining up.
      local handle = open()
      narrow(handle, 20)

      window.set_winbar(handle, HEADER)

      assert.are.equal("NAME  IMAGE  STATUS>", rendered_winbar(handle))
    end)

    it("shows the header as is when it fits", function()
      local handle = open()
      narrow(handle, #HEADER)

      window.set_winbar(handle, HEADER)

      assert.are.equal(HEADER, rendered_winbar(handle))
    end)

    it("shifts the header by the same amount when the view scrolls horizontally", function()
      -- Without following along, the header and the columns disagree wherever the view scrolls to.
      local handle = open()
      narrow(handle, 20)
      window.set_lines(handle, { string.rep("x", 200) })
      window.set_winbar(handle, HEADER)

      vim.api.nvim_win_call(handle.winid, function()
        vim.fn.winrestview({ leftcol = 6 })
      end)
      window.sync_winbar(handle)

      -- Six columns are dropped from the head, and the tail that does not fit into width 20
      -- is taken up by `>`.
      assert.are.equal("IMAGE  STATUS  PORT>", rendered_winbar(handle))
      -- The color must still be applied after the header is re-clipped.
      assert.are.same({ { start = 0, group = "DockerHeader" } }, applied_highlights(handle))
    end)

    it("makes the header follow along on cursor movement", function()
      -- It must follow along from the interaction alone, without being called explicitly.
      local handle = open()
      narrow(handle, 20)
      window.set_lines(handle, { string.rep("x", 200) })
      window.set_winbar(handle, HEADER)
      assert.are.equal("NAME  IMAGE  STATUS>", rendered_winbar(handle))

      vim.api.nvim_win_call(handle.winid, function()
        vim.fn.winrestview({ leftcol = 6 })
      end)
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.bufnr })

      assert.are.equal("IMAGE  STATUS  PORT>", rendered_winbar(handle))
    end)

    it("follows along even for scrolling that does not move the cursor", function()
      -- `zl` / `zh` scroll sideways without moving the cursor. Watching only CursorMoved would
      -- leave the header behind in that case.
      local handle = open()
      narrow(handle, 20)
      window.set_lines(handle, { string.rep("x", 200) })
      window.set_winbar(handle, HEADER)

      vim.api.nvim_win_call(handle.winid, function()
        vim.fn.winrestview({ leftcol = 6 })
      end)
      vim.api.nvim_exec_autocmds("WinScrolled", { buffer = handle.bufnr })

      assert.are.equal("IMAGE  STATUS  PORT>", rendered_winbar(handle))
    end)

    it("cuts a full-width header by display width too", function()
      -- Dropping by bytes would shift the cut position for a full-width header.
      -- Each of these characters is 3 bytes long but 2 columns wide, so the two units disagree.
      local handle = open()
      narrow(handle, 20)
      window.set_winbar(handle, "ＡＢ  ＣＤＥＦ  ＧＨ")

      vim.api.nvim_win_call(handle.winid, function()
        vim.fn.winrestview({ leftcol = 6 })
      end)
      window.sync_winbar(handle)

      assert.are.equal("ＣＤＥＦ  ＧＨ", rendered_winbar(handle))
    end)

    it("applies the dedicated highlight to the whole header", function()
      local handle = open()
      narrow(handle, 20)

      window.set_winbar(handle, HEADER)

      assert.are.same({ { start = 0, group = "DockerHeader" } }, applied_highlights(handle))
    end)

    it("does not interpret a % in the header as a format item", function()
      -- The winbar uses statusline format, so passing text through unescaped would expand `%d` and friends.
      local handle = open()

      window.set_winbar(handle, "USE%  MEM%")

      assert.are.equal("USE%  MEM%", rendered_winbar(handle))
    end)

    it("does not mix up the headers of multiple windows", function()
      local containers = open({ title = "Containers" })
      local images = open({ title = "Images" })
      narrow(containers, 20)
      narrow(images, 20)
      window.set_winbar(containers, HEADER)
      window.set_winbar(images, "REPOSITORY  TAG")

      vim.api.nvim_win_call(containers.winid, function()
        vim.fn.winrestview({ leftcol = 6 })
      end)
      window.sync_winbar(containers)

      assert.are.same(
        { "IMAGE  STATUS  PORT>", "REPOSITORY  TAG" },
        { rendered_winbar(containers), rendered_winbar(images) }
      )
    end)

    it("does not add another follow-along hook on redraw", function()
      -- Stacking one on every redraw would make a single scroll run it many times.
      local handle = open()

      window.set_winbar(handle, HEADER)
      window.set_winbar(handle, HEADER)
      window.set_winbar(handle, HEADER)

      local watchers = vim.api.nvim_get_autocmds({ buffer = handle.bufnr, event = "CursorMoved" })
      assert.are.equal(1, #watchers)
    end)
  end)

  describe("set_lines", function()
    it("can write lines into a non-modifiable buffer", function()
      local handle = open()

      window.set_lines(handle, { "web    alpine", "db     postgres" })

      assert.are.same({ "web    alpine", "db     postgres" }, vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false))
    end)

    it("leaves the buffer non-modifiable after writing", function()
      local handle = open()

      window.set_lines(handle, { "web" })

      assert.is_false(vim.bo[handle.bufnr].modifiable)
    end)

    it("leaves none of the previous content behind when the lines are replaced", function()
      local handle = open()
      window.set_lines(handle, { "a", "b", "c" })

      window.set_lines(handle, { "x" })

      assert.are.same({ "x" }, vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false))
    end)
  end)

  describe("close", function()
    it("closes the window", function()
      local handle = window.open({ title = "Containers" })

      window.close(handle)

      assert.is_false(vim.api.nvim_win_is_valid(handle.winid))
    end)

    it("discards the buffer as well on close", function()
      -- Leaving it around would pile up unnamed buffers with every open and close.
      local handle = window.open({ title = "Containers" })

      window.close(handle)

      assert.is_false(vim.api.nvim_buf_is_valid(handle.bufnr))
    end)

    it("does not error when an already closed window is closed again", function()
      local handle = window.open({ title = "Containers" })
      window.close(handle)

      window.close(handle)

      assert.is_false(vim.api.nvim_win_is_valid(handle.winid))
    end)
  end)

  describe("VimResized", function()
    it("makes the window size follow along when the editor width changes", function()
      local original = vim.o.columns
      local handle = open()
      local before = vim.api.nvim_win_get_config(handle.winid).width

      vim.o.columns = original + 40
      vim.api.nvim_exec_autocmds("VimResized", {})
      local after = vim.api.nvim_win_get_config(handle.winid).width

      vim.o.columns = original
      vim.api.nvim_exec_autocmds("VimResized", {})

      assert.is_true(after > before, ("the width must follow along: before=%d after=%d"):format(before, after))
    end)
  end)
end)
