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
        },
      }, items)
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
end)
