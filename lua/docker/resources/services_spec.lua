local services = require("docker.resources.services")

---@param overrides table|nil
---@return table
local function container(overrides)
  return vim.tbl_extend("force", {
    id = "abc123",
    name = "shop-web-1",
    image = "alpine",
    state = "running",
    status = "Up 5 days",
    ports = "",
    command = '"sleep"',
    created_at = "now",
    compose_project = "shop",
    compose_service = "web",
    compose_oneoff = "False",
  }, overrides or {})
end

---@param names string[]
---@return docker.ComposeProject
local function project(names)
  return { name = "shop", working_dir = "/work/shop", service_names = names }
end

describe("docker.resources.services", function()
  describe("assemble", function()
    it("サービス名とコンテナをラベルで突き合わせる", function()
      local items = services.assemble(project({ "web" }), { container() })

      assert.are.same({
        {
          project = "shop",
          name = "web",
          container = "shop-web-1",
          container_id = "abc123",
          status = "running",
          working_dir = "/work/shop",
        },
      }, items)
    end)

    it("compose ファイルのある場所を各行に持たせる", function()
      -- 起動系の操作は compose ファイルが読める場所でしか実行できないため、
      -- 行ごとにその場所を持たせて操作側が参照できるようにする。
      local items = services.assemble(project({ "web", "never-started" }), { container() })

      assert.are.equal("/work/shop", items[1].working_dir)
      assert.are.equal("/work/shop", items[2].working_dir)
    end)

    it("対応するコンテナが無いサービスは状態がnoneになる", function()
      -- BR-005: 定義されているが起動していないサービスも一覧に出す。
      local items = services.assemble(project({ "web", "never-started" }), { container() })

      local by_name = {}
      for _, item in ipairs(items) do
        by_name[item.name] = item
      end
      assert.are.equal("none", by_name["never-started"].status)
      assert.are.equal("", by_name["never-started"].container)
      assert.are.equal("running", by_name["web"].status)
    end)

    it("単発コンテナはサービスに紐付けない", function()
      -- BR-006: `docker compose run` が作るコンテナはサービスの実体ではない。
      local items = services.assemble(project({ "worker" }), {
        container({ id = "one", name = "shop-worker-run-abc", compose_service = "worker", compose_oneoff = "True" }),
      })

      assert.are.equal(1, #items)
      assert.are.equal("none", items[1].status)
      assert.are.equal("", items[1].container)
    end)

    it("単発コンテナがあっても本来のコンテナがあればそちらを使う", function()
      local items = services.assemble(project({ "worker" }), {
        container({ id = "one", name = "shop-worker-run-abc", compose_service = "worker", compose_oneoff = "True" }),
        container({ id = "real", name = "shop-worker-1", compose_service = "worker", compose_oneoff = "False" }),
      })

      assert.are.equal(1, #items)
      assert.are.equal("shop-worker-1", items[1].container)
      assert.are.equal("running", items[1].status)
    end)

    it("同じサービスに複数のコンテナがあるとき稼働中を代表にする", function()
      -- scale したサービスで、先頭が停止していると稼働レプリカがあっても
      -- 停止として見えてしまう。
      local items = services.assemble(project({ "web" }), {
        container({ id = "1", name = "shop-web-1", state = "exited" }),
        container({ id = "2", name = "shop-web-2", state = "running" }),
      })

      assert.are.equal("running", items[1].status)
      assert.are.equal("shop-web-2", items[1].container)
    end)

    it("すべて停止しているときはその状態を出す", function()
      local items = services.assemble(project({ "web" }), {
        container({ id = "1", name = "shop-web-1", state = "exited" }),
        container({ id = "2", name = "shop-web-2", state = "exited" }),
      })

      assert.are.equal("exited", items[1].status)
    end)

    it("別プロジェクトのコンテナは紐付けない", function()
      local items = services.assemble(project({ "web" }), {
        container({ compose_project = "other", name = "other-web-1" }),
      })

      assert.are.equal("none", items[1].status)
    end)

    it("compose由来でないコンテナは無視する", function()
      local items = services.assemble(project({ "web" }), {
        container({ compose_project = "", compose_service = "", name = "plain" }),
      })

      assert.are.equal("none", items[1].status)
    end)

    it("定義に無いサービスのコンテナは一覧に出さない", function()
      -- compose.yaml から消えたサービスの残骸を出さない。
      local items = services.assemble(project({ "web" }), {
        container(),
        container({ id = "ghost", name = "shop-ghost-1", compose_service = "ghost" }),
      })

      assert.are.equal(1, #items)
      assert.are.equal("web", items[1].name)
    end)

    it("サービスは定義の順序で並ぶ", function()
      local items = services.assemble(project({ "alpha", "mid", "zeta" }), {})

      local names = {}
      for _, item in ipairs(items) do
        table.insert(names, item.name)
      end
      assert.are.same({ "alpha", "mid", "zeta" }, names)
    end)

    it("停止したコンテナの状態をそのまま反映する", function()
      local items = services.assemble(project({ "web" }), {
        container({ state = "exited", status = "Exited (0) 1 minute ago" }),
      })

      assert.are.equal("exited", items[1].status)
    end)

    it("サービスが0件なら空を返す", function()
      assert.are.same({}, services.assemble(project({}), { container() }))
    end)
  end)

  describe("derive_service_names", function()
    -- compose ファイルを読めないプロジェクトでは定義を引けない。
    -- そのときはコンテナのラベルからサービス名を逆算する。
    it("そのプロジェクトのコンテナからサービス名を取り出す", function()
      local names = services.derive_service_names("shop", {
        container({ compose_service = "web" }),
        container({ id = "2", compose_service = "db" }),
      })

      assert.are.same({ "db", "web" }, names)
    end)

    it("同じサービスの複数コンテナを1つにまとめる", function()
      local names = services.derive_service_names("shop", {
        container({ id = "1", name = "shop-web-1", compose_service = "web" }),
        container({ id = "2", name = "shop-web-2", compose_service = "web" }),
      })

      assert.are.same({ "web" }, names)
    end)

    it("別プロジェクトのコンテナは含めない", function()
      local names = services.derive_service_names("shop", {
        container({ compose_service = "web" }),
        container({ id = "2", compose_project = "blog", compose_service = "cms" }),
      })

      assert.are.same({ "web" }, names)
    end)

    it("単発コンテナはサービスとして数えない", function()
      -- BR-006: `docker compose run` が作るコンテナはサービスの実体ではない。
      local names = services.derive_service_names("shop", {
        container({ compose_service = "worker", compose_oneoff = "True" }),
      })

      assert.are.same({}, names)
    end)

    it("該当するコンテナが無ければ空を返す", function()
      assert.are.same({}, services.derive_service_names("shop", {}))
    end)
  end)

  describe("assemble_all", function()
    it("複数プロジェクトのサービスを1つの一覧にまとめる", function()
      local items = services.assemble_all({
        { name = "shop", working_dir = "/work/shop", service_names = { "web" } },
        { name = "blog", working_dir = "/work/blog", service_names = { "cms" } },
      }, {
        container({ compose_project = "shop", compose_service = "web" }),
        container({ id = "b1", name = "blog-cms-1", compose_project = "blog", compose_service = "cms" }),
      })

      assert.are.same({
        {
          project = "blog",
          name = "cms",
          container = "blog-cms-1",
          container_id = "b1",
          status = "running",
          working_dir = "/work/blog",
        },
        {
          project = "shop",
          name = "web",
          container = "shop-web-1",
          container_id = "abc123",
          status = "running",
          working_dir = "/work/shop",
        },
      }, items)
    end)

    it("プロジェクトは名前順に並ぶ", function()
      -- 取得元の順序は実行のたびに変わりうる。行の並びを実行ごとに変えない。
      local items = services.assemble_all({
        { name = "zeta", working_dir = "/z", service_names = { "a" } },
        { name = "alpha", working_dir = "/a", service_names = { "a" } },
        { name = "mid", working_dir = "/m", service_names = { "a" } },
      }, {})

      local names = {}
      for _, item in ipairs(items) do
        table.insert(names, item.project)
      end
      assert.are.same({ "alpha", "mid", "zeta" }, names)
    end)

    it("同名のサービスが別プロジェクトにあっても両方出す", function()
      local items = services.assemble_all({
        { name = "shop", working_dir = "/work/shop", service_names = { "web" } },
        { name = "blog", working_dir = "/work/blog", service_names = { "web" } },
      }, {})

      assert.are.equal(2, #items)
      assert.are.equal("blog", items[1].project)
      assert.are.equal("shop", items[2].project)
    end)

    it("プロジェクトが0件なら空を返す", function()
      assert.are.same({}, services.assemble_all({}, { container() }))
    end)
  end)
end)
