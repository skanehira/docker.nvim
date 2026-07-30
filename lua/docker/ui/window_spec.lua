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

  --- 実際に画面へ出る winbar。オプションの生の値には切り詰めの書式が入るため、
  --- 描画結果で確かめる。
  ---@param handle docker.Window
  ---@return string
  local function rendered_winbar(handle)
    return vim.api.nvim_eval_statusline(vim.wo[handle.winid].winbar, {
      winid = handle.winid,
      maxwidth = vim.api.nvim_win_get_width(handle.winid),
      use_winbar = true,
    }).str
  end

  --- winbar に当たっているハイライト。`groups` は Neovim 0.11 で増えたので、
  --- 0.10 でも取れる項目だけに絞って比べる。
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

  --- 窓を細くして、見出しがはみ出す状況を作る。
  ---@param handle docker.Window
  ---@param width integer
  local function narrow(handle, width)
    local config = vim.api.nvim_win_get_config(handle.winid)
    config.width = width
    vim.api.nvim_win_set_config(handle.winid, config)
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

    it("折り返しの有無を指定できる", function()
      -- 一覧は折り返すと行と画面行がずれ、見出しと桁が合わなくなる。
      local wrapped = open({ title = "Wrapped" })
      local clipped = open({ title = "Clipped", wrap = false })

      assert.are.same({ true, false }, { vim.wo[wrapped.winid].wrap, vim.wo[clipped.winid].wrap })
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

  describe("set_winbar", function()
    local HEADER = "NAME  IMAGE  STATUS  PORTS  PROJECT  SERVICE"

    before_each(function()
      -- 見出しのハイライトは本番では lifecycle が定義する。
      require("docker.ui.highlight").setup()
    end)

    it("はみ出すときは末尾を落とす", function()
      -- 既定では先頭が落ちて `<` が付く。本文は右端でクリップされるので、
      -- 見出しだけが左へずれて桁が合わなくなる。
      local handle = open()
      narrow(handle, 20)

      window.set_winbar(handle, HEADER)

      assert.are.equal("NAME  IMAGE  STATUS>", rendered_winbar(handle))
    end)

    it("収まるときはそのまま出す", function()
      local handle = open()
      narrow(handle, #HEADER)

      window.set_winbar(handle, HEADER)

      assert.are.equal(HEADER, rendered_winbar(handle))
    end)

    it("横スクロールすると見出しもその分ずれる", function()
      -- 追従しないと、スクロールした先で見出しと列が食い違う。
      local handle = open()
      narrow(handle, 20)
      window.set_lines(handle, { string.rep("x", 200) })
      window.set_winbar(handle, HEADER)

      vim.api.nvim_win_call(handle.winid, function()
        vim.fn.winrestview({ leftcol = 6 })
      end)
      window.sync_winbar(handle)

      -- 6 桁ぶん先頭を落とし、幅 20 に収まらない末尾が `>` に潰れる。
      assert.are.equal("IMAGE  STATUS  PORT>", rendered_winbar(handle))
      -- 切り直した後も色は乗ったままであること。
      assert.are.same({ { start = 0, group = "DockerHeader" } }, applied_highlights(handle))
    end)

    it("カーソル移動を合図に見出しが追従する", function()
      -- 明示的に呼ばなくても、操作しただけで追従すること。
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

    it("カーソルが動かないスクロールでも追従する", function()
      -- `zl` / `zh` はカーソルを動かさずに横へ送る。CursorMoved だけを見ていると
      -- このとき見出しが取り残される。
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

    it("全角の見出しも表示幅で切る", function()
      -- バイト単位で落とすと、全角の見出しでは切る位置がずれる。
      local handle = open()
      narrow(handle, 20)
      window.set_winbar(handle, "名前  イメージ  状態")

      vim.api.nvim_win_call(handle.winid, function()
        vim.fn.winrestview({ leftcol = 6 })
      end)
      window.sync_winbar(handle)

      assert.are.equal("イメージ  状態", rendered_winbar(handle))
    end)

    it("見出し全体に専用のハイライトを当てる", function()
      local handle = open()
      narrow(handle, 20)

      window.set_winbar(handle, HEADER)

      assert.are.same({ { start = 0, group = "DockerHeader" } }, applied_highlights(handle))
    end)

    it("見出しに%が入っても書式として解釈しない", function()
      -- winbar は statusline 書式なので、素通しすると `%d` 等が展開される。
      local handle = open()

      window.set_winbar(handle, "USE%  MEM%")

      assert.are.equal("USE%  MEM%", rendered_winbar(handle))
    end)

    it("複数の窓で見出しが混ざらない", function()
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

    it("描き直しても追従の仕掛けが増えない", function()
      -- 再描画のたびに張り重ねると、スクロール 1 回で何度も走る。
      local handle = open()

      window.set_winbar(handle, HEADER)
      window.set_winbar(handle, HEADER)
      window.set_winbar(handle, HEADER)

      local watchers = vim.api.nvim_get_autocmds({ buffer = handle.bufnr, event = "CursorMoved" })
      assert.are.equal(1, #watchers)
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
