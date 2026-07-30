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

  describe("open", function()
    it("エディタ基準のフロートウィンドウを開く", function()
      local handle = open()

      local config = vim.api.nvim_win_get_config(handle.winid)
      assert.are.equal("editor", config.relative)
    end)

    it("外枠とタイトルを持つ", function()
      local handle = open({ title = "Containers" })

      local config = vim.api.nvim_win_get_config(handle.winid)
      assert.is_truthy(config.border, "border が設定されていること")
      -- title は { { text, hl } } の形で返る。
      assert.are.equal("Containers", config.title[1][1])
    end)

    it("カラム見出しをwinbarに入れる", function()
      -- 見出しをバッファに入れないことで、カーソル行とデータ行の添字が 1 対 1 になる。
      local handle = open({ winbar = "NAME  IMAGE  STATUS" })

      assert.are.equal("NAME  IMAGE  STATUS", vim.wo[handle.winid].winbar)
    end)

    it("バッファは書き込み対象にならない設定になる", function()
      local handle = open()

      assert.are.equal("nofile", vim.bo[handle.bufnr].buftype)
      assert.is_false(vim.bo[handle.bufnr].modifiable)
      assert.is_false(vim.bo[handle.bufnr].swapfile)
    end)

    it("重ね合わせの高さを指定できる", function()
      local lower = open({ zindex = 40 })
      local upper = open({ zindex = 60 })

      assert.are.equal(40, vim.api.nvim_win_get_config(lower.winid).zindex)
      assert.are.equal(60, vim.api.nvim_win_get_config(upper.winid).zindex)
    end)

    it("本体と外枠の背景をエディタと同じにし、minimalの指定も残す", function()
      -- 既定のままだと本文は NormalFloat の背景で塗られ、winbar だけが
      -- 透過して見える。背景を Normal に寄せてフロート全体を揃える。
      -- あわせて style="minimal" が入れる EndOfBuffer の打ち消しを消さない。
      -- 上書きすると、EndOfBuffer に背景色を持つカラースキームで
      -- データ行より下だけ別色になる。
      local handle = open()

      -- 並び順に左右されないよう、対応表に開いて比べる。
      local winhighlight = vim.wo[handle.winid].winhighlight
      local mapping = {}
      for pair in winhighlight:gmatch("[^,]+") do
        local from, to = pair:match("^([^:]*):(.*)$")
        mapping[from] = to
      end
      assert.are.same({ EndOfBuffer = "", NormalFloat = "Normal", FloatBorder = "Normal" }, mapping)

      -- 追記の仕方を誤ると同じ指定が二重に入る。対応表では潰れて見えない。
      local _, occurrences = winhighlight:gsub("NormalFloat:", "")
      assert.are.equal(1, occurrences, winhighlight)
    end)

    it("エディタの中央に配置する", function()
      local handle = open()

      local config = vim.api.nvim_win_get_config(handle.winid)
      assert.are.equal(math.floor((vim.o.columns - config.width) / 2), config.col)
    end)
  end)

  describe("set_lines", function()
    it("書き込み不可のバッファにも行を書ける", function()
      local handle = open()

      window.set_lines(handle, { "web    alpine", "db     postgres" })

      assert.are.same({ "web    alpine", "db     postgres" }, vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false))
    end)

    it("書き込んだ後も書き込み不可のままになる", function()
      local handle = open()

      window.set_lines(handle, { "web" })

      assert.is_false(vim.bo[handle.bufnr].modifiable)
    end)

    it("行を差し替えると前の内容は残らない", function()
      local handle = open()
      window.set_lines(handle, { "a", "b", "c" })

      window.set_lines(handle, { "x" })

      assert.are.same({ "x" }, vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false))
    end)
  end)

  describe("close", function()
    it("ウィンドウを閉じる", function()
      local handle = window.open({ title = "Containers" })

      window.close(handle)

      assert.is_false(vim.api.nvim_win_is_valid(handle.winid))
    end)

    it("閉じるとバッファも破棄される", function()
      -- 残したままだと開閉のたびに無名バッファが溜まる。
      local handle = window.open({ title = "Containers" })

      window.close(handle)

      assert.is_false(vim.api.nvim_buf_is_valid(handle.bufnr))
    end)

    it("既に閉じたウィンドウをもう一度閉じてもエラーにならない", function()
      local handle = window.open({ title = "Containers" })
      window.close(handle)

      window.close(handle)

      assert.is_false(vim.api.nvim_win_is_valid(handle.winid))
    end)
  end)

  describe("VimResized", function()
    it("エディタの幅が変わるとウィンドウの大きさが追従する", function()
      local original = vim.o.columns
      local handle = open()
      local before = vim.api.nvim_win_get_config(handle.winid).width

      vim.o.columns = original + 40
      vim.api.nvim_exec_autocmds("VimResized", {})
      local after = vim.api.nvim_win_get_config(handle.winid).width

      vim.o.columns = original
      vim.api.nvim_exec_autocmds("VimResized", {})

      assert.is_true(after > before, ("幅が追従すること: before=%d after=%d"):format(before, after))
    end)
  end)
end)
