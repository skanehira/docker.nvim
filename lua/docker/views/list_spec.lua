local list = require("docker.views.list")
local registry = require("docker.resources.registry")
local tbl = require("docker.ui.table")

--- 一覧取得で得られるコンテナの生データ。指定した項目だけ上書きする。
---@param overrides table|nil
---@return table
local function container(overrides)
  return vim.tbl_extend("force", {
    id = "abc123",
    name = "web",
    image = "alpine:3.20",
    state = "running",
    status = "Up 5 days",
    ports = "",
    command = '"sleep 600"',
    created_at = "2026-07-29 10:00:00 +0900 JST",
    compose_project = "",
    compose_service = "",
    compose_oneoff = "",
  }, overrides or {})
end

describe("docker.views.list", function()
  ---@type docker.ResourceDefinition
  local def

  before_each(function()
    def = assert(registry.get("container"))
  end)

  describe("build", function()
    it("見出しはバッファ行に含めずwinbarに入れる", function()
      -- 見出しをバッファに入れないことで、カーソル行とデータ行の添字が 1 対 1 になる。
      local built = list.build(def, { container() })

      assert.are.equal(1, #built.lines)
      assert.is_truthy(built.winbar:find("NAME", 1, true))
      assert.is_truthy(built.winbar:find("STATUS", 1, true))
    end)

    it("リソース1件につきバッファ行を1行生成する", function()
      local built = list.build(def, {
        container({ id = "1", name = "web" }),
        container({ id = "2", name = "db" }),
        container({ id = "3", name = "cache" }),
      })

      assert.are.equal(3, #built.lines)
    end)

    it("compose由来のコンテナはPROJECTとSERVICEの値が行に出る", function()
      -- 名前・プロジェクト名・サービス名を互いに異なる値にする。
      -- コンテナ名に含まれる語で照合すると、列が空でもテストが通ってしまう。
      local built = list.build(def, {
        container({
          name = "ctr",
          image = "img",
          status = "Up",
          compose_project = "projalpha",
          compose_service = "svcbeta",
          compose_oneoff = "False",
        }),
      })

      -- 列幅は見出し (NAME/IMAGE/STATUS/PORTS/PROJECT/SERVICE) の長さで決まる。
      -- PORTS は空なので、STATUS と PROJECT の間はその幅ぶん空く。
      assert.are.equal("ctr   img    Up             projalpha  svcbeta", built.lines[1])
    end)

    it("compose由来でないコンテナはPROJECTとSERVICEが空欄になる", function()
      local built = list.build(def, { container({ name = "plain" }) })

      -- 末尾の余白は残さないので、compose 列が空なら行は SERVICE の手前で終わる。
      assert.are.equal("plain  alpine:3.20  Up 5 days", built.lines[1])
    end)

    it("0件のときは項目が無いことを示す1行を出す", function()
      local built = list.build(def, {})

      assert.are.same({ "コンテナがありません" }, built.lines)
    end)

    it("0件のときも見出しは出す", function()
      local built = list.build(def, {})

      assert.is_truthy(built.winbar:find("NAME", 1, true))
    end)

    it("列は各行の最大幅に揃う", function()
      local built = list.build(def, {
        container({ id = "1", name = "web" }),
        container({ id = "2", name = "very-long-container-name" }),
      })

      -- 2 行とも IMAGE 列が同じ桁から始まる。
      local first = built.lines[1]:find("alpine", 1, true)
      local second = built.lines[2]:find("alpine", 1, true)
      assert.are.equal(first, second)
    end)
  end)

  describe("item_at", function()
    it("カーソル行に対応するリソースを返す", function()
      local items = { container({ id = "1" }), container({ id = "2" }), container({ id = "3" }) }

      assert.are.equal("2", list.item_at(items, 2).id)
    end)

    it("0件のときはどの行を指してもnilを返す", function()
      assert.is_nil(list.item_at({}, 1))
    end)

    it("項目数を超える行はnilを返す", function()
      assert.is_nil(list.item_at({ container() }, 2))
    end)

    it("0以下の行はnilを返す", function()
      assert.is_nil(list.item_at({ container() }, 0))
    end)
  end)

  describe("render", function()
    local window = require("docker.ui.window")
    local handle

    after_each(function()
      if handle then
        window.close(handle)
        handle = nil
      end
    end)

    it("行が長くて収まらなくても見出しと本文の桁が一致する", function()
      -- 収まらないとき、winbar は既定では先頭が落ちるため見出しだけが左へずれる。
      handle = window.open({ title = "Containers", wrap = false })

      local built = list.render(handle, def, {
        container({ id = "1", name = "web", ports = string.rep("0.0.0.0:5001->5000/tcp, ", 8) }),
      })

      -- 画面に出ている見出しが、行と同じ幅で組んだ見出しの先頭と一致すること。
      -- 末尾の 1 桁は切り詰めの印に潰れる。
      local width = vim.api.nvim_win_get_width(handle.winid)
      local rendered = vim.api.nvim_eval_statusline(vim.wo[handle.winid].winbar, {
        winid = handle.winid,
        maxwidth = width,
        use_winbar = true,
      }).str
      assert.are.equal(built.winbar:sub(1, width - 1) .. ">", rendered)

      -- 全ての列で、見出しと本文の開始桁が揃っていること。
      local headers = {}
      for _, column in ipairs(def.columns) do
        table.insert(headers, column.header)
      end
      local header_starts, row_starts = {}, {}
      for index = 1, #headers do
        table.insert(header_starts, (tbl.column_span(headers, built.widths, index)))
        table.insert(row_starts, (tbl.column_span(built.rows[1], built.widths, index)))
      end
      assert.are.same(header_starts, row_starts)
    end)

    it("ウィンドウに行と見出しを反映する", function()
      handle = window.open({ title = "Containers" })

      list.render(handle, def, { container({ name = "web" }), container({ name = "db" }) })

      local lines = vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)
      assert.are.equal(2, #lines)
      assert.is_truthy(lines[1]:find("web", 1, true))
      assert.is_truthy(vim.wo[handle.winid].winbar:find("NAME", 1, true))
    end)

    it("再描画しても前の内容は残らない", function()
      handle = window.open({ title = "Containers" })
      list.render(handle, def, { container({ name = "web" }), container({ name = "db" }) })

      list.render(handle, def, { container({ name = "cache" }) })

      assert.are.equal(1, #vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false))
    end)
  end)

  describe("表示行の安全性", function()
    local window = require("docker.ui.window")

    it("改行を含む値があっても一覧全体が描画できる", function()
      -- compose のラベル値は任意の文字を取れる。改行を含む値が 1 件でもあると
      -- nvim_buf_set_lines が失敗し、一覧そのものが出せなくなる。
      local handle = window.open({ title = "Containers" })

      list.render(handle, def, {
        container({ id = "1", name = "plain" }),
        container({ id = "2", name = "evil", compose_project = "proj\nEVIL" }),
      })

      local lines = vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)
      assert.are.equal(2, #lines, "2 件とも描画されること")
      assert.is_truthy(lines[2]:find("proj EVIL", 1, true), lines[2])
      window.close(handle)
    end)

    it("復帰やタブを含む値も1行に収める", function()
      local handle = window.open({ title = "Containers" })

      list.render(handle, def, { container({ name = "a\tb\rc" }) })

      local lines = vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)
      assert.are.equal(1, #lines)
      assert.is_nil(lines[1]:find("\t", 1, true))
      window.close(handle)
    end)

    it("改行を含む値でも桁揃えが崩れない", function()
      local handle = window.open({ title = "Containers" })

      list.render(handle, def, {
        container({ id = "1", name = "one", compose_project = "aa\nbb" }),
        container({ id = "2", name = "two", compose_project = "cccc" }),
      })

      local lines = vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false)
      assert.are.equal(lines[1]:find("aa bb", 1, true), lines[2]:find("cccc", 1, true))
      window.close(handle)
    end)

    it("閉じたウィンドウへ描画してもエラーにならない", function()
      -- 取得中にビューを閉じると、結果が返ってきた時点でバッファは無効になっている。
      local handle = window.open({ title = "Containers" })
      window.close(handle)

      list.render(handle, def, { container() })
    end)
  end)

  describe("各リソース種別の描画", function()
    -- G6 の検証手順が list_spec に「各種別の一覧が描画されること」を求めている。
    local samples = {
      image = { id = "i1", repository = "alpine", tag = "3.20", size = "5MB", created_since = "2 days ago" },
      volume = { name = "v1", driver = "local", mountpoint = "/var/lib/docker/volumes/v1" },
      network = { id = "n1", name = "bridge", driver = "bridge", scope = "local" },
      service = { project = "shop", name = "web", container = "shop-web-1", container_id = "c1", status = "running" },
    }

    it("種別ごとに見出しと行が生成される", function()
      local expected = {
        image = { "REPOSITORY  TAG   SIZE  CREATED", "alpine      3.20  5MB   2 days ago" },
        volume = { "NAME  DRIVER  MOUNTPOINT", "v1    local   /var/lib/docker/volumes/v1" },
        network = { "NAME    DRIVER  SCOPE", "bridge  bridge  local" },
        service = { "PROJECT  SERVICE  STATUS   CONTAINER", "shop     web      running  shop-web-1" },
      }

      local actual = {}
      for kind, item in pairs(samples) do
        local built = list.build(assert(registry.get(kind)), { item })
        actual[kind] = { built.winbar, built.lines[1] }
      end

      assert.are.same(expected, actual)
    end)

    it("種別ごとに0件の文言が出る", function()
      local actual = {}
      for kind in pairs(samples) do
        actual[kind] = list.build(assert(registry.get(kind)), {}).lines
      end

      assert.are.same({
        image = { "イメージがありません" },
        volume = { "ボリュームがありません" },
        network = { "ネットワークがありません" },
        service = { "compose プロジェクトがありません" },
      }, actual)
    end)
  end)
end)
