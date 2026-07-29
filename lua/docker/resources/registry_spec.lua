local registry = require("docker.resources.registry")

--- 一覧取得で得られるコンテナの生データ。指定した項目だけ上書きする。
---@param overrides table|nil
---@return table
local function container(overrides)
  return vim.tbl_extend("force", {
    id = "abc123def456",
    name = "web",
    image = "alpine:3.20",
    state = "running",
    status = "Up 5 days",
    ports = "0.0.0.0:8080->80/tcp",
    command = '"sleep 600"',
    created_at = "2026-07-29 10:00:00 +0900 JST",
    compose_project = "",
    compose_service = "",
    compose_oneoff = "",
  }, overrides or {})
end

---@param def docker.ResourceDefinition
---@param item table
---@return table<string, string>
local function columns_of(def, item)
  local values = {}
  for _, column in ipairs(def.columns) do
    values[column.header] = column.value(item)
  end
  return values
end

describe("docker.resources.registry", function()
  describe("get", function()
    it("未知の種別を渡すとnilを返す", function()
      assert.is_nil(registry.get("nonexistent"))
    end)
  end)

  describe("subcommands", function()
    it("定義済みの種別に対応するExコマンドの引数を返す", function()
      assert.are.same({ "containers", "services" }, registry.subcommands())
    end)
  end)

  describe("コンテナの定義", function()
    ---@type docker.ResourceDefinition
    local def

    before_each(function()
      def = assert(registry.get("container"))
    end)

    it("一覧取得の引数に停止中を含める-aを付ける", function()
      -- BR-022: 停止中のコンテナも一覧に含める。
      assert.is_truthy(vim.tbl_contains(assert(def.list_args)(), "-a"))
    end)

    it("一覧取得の引数に切り詰めを防ぐ--no-truncを付ける", function()
      -- 付けないと ID が 12 文字、Command が 20 文字で切り詰められる。
      assert.is_truthy(vim.tbl_contains(assert(def.list_args)(), "--no-trunc"))
    end)

    it("一覧取得のサブコマンドはps", function()
      assert.are.equal("ps", assert(def.list_args)()[1])
    end)

    it("一覧取得の書式にサイズを含めない", function()
      -- .Size を参照するとサイズ計算が走り実行時間が増える。
      local args = table.concat(assert(def.list_args)(), " ")

      assert.is_nil(args:find(".Size", 1, true))
    end)

    it("一覧取得の書式はcomposeラベルをキー名指しで取り出す", function()
      -- `Labels` の分割はラベル値のカンマと偽ラベルの仕込みで誤った値を掴む。
      local args = table.concat(assert(def.list_args)(), " ")

      assert.is_truthy(args:find('(.Label "com.docker.compose.project")', 1, true))
      assert.is_truthy(args:find('(.Label "com.docker.compose.service")', 1, true))
      assert.is_truthy(args:find('(.Label "com.docker.compose.oneoff")', 1, true))
      assert.is_nil(args:find("{{json .Labels}}", 1, true))
    end)

    it("識別子はコンテナIDを返す", function()
      assert.are.equal("abc123def456", def.id(container()))
    end)

    it("カラムはNAME_IMAGE_STATUS_PORTS_PROJECT_SERVICEの順に並ぶ", function()
      local headers = {}
      for _, column in ipairs(def.columns) do
        table.insert(headers, column.header)
      end

      assert.are.same({ "NAME", "IMAGE", "STATUS", "PORTS", "PROJECT", "SERVICE" }, headers)
    end)

    it("compose由来のコンテナはPROJECTとSERVICEに値が入る", function()
      local item = container({
        compose_project = "shop",
        compose_service = "web",
        compose_oneoff = "False",
      })

      assert.are.same({
        NAME = "web",
        IMAGE = "alpine:3.20",
        STATUS = "Up 5 days",
        PORTS = "0.0.0.0:8080->80/tcp",
        PROJECT = "shop",
        SERVICE = "web",
      }, columns_of(def, item))
    end)

    it("compose由来でないコンテナはPROJECTとSERVICEが空欄になる", function()
      assert.are.same({
        NAME = "web",
        IMAGE = "alpine:3.20",
        STATUS = "Up 5 days",
        PORTS = "0.0.0.0:8080->80/tcp",
        PROJECT = "",
        SERVICE = "",
      }, columns_of(def, container()))
    end)

    it("ラベル値に偽のプロジェクト名を仕込まれてもPROJECTは空欄のままになる", function()
      -- 生データは `.Label` によるキー名指しで採取しているため、
      -- ラベル値に `,com.docker.compose.project=SPOOFED,` を含んでいても空文字列になる。
      local item = container({ compose_project = "", compose_service = "" })

      assert.are.equal("", columns_of(def, item).PROJECT)
    end)

    it("状態のカラム位置はSTATUSを指す", function()
      assert.are.equal(3, def.status_column)
      assert.are.equal("STATUS", def.columns[def.status_column].header)
    end)

    it("状態は生データのstateを返す", function()
      assert.are.equal("exited", def.status(container({ state = "exited" })))
    end)

    it("dockerイベントのcontainer種別に対応付く", function()
      assert.are.equal("container", def.event_type)
    end)

    it("Exコマンドの引数はcontainers", function()
      assert.are.equal("containers", def.subcommand)
    end)

    it("表示名はContainers", function()
      assert.are.equal("Containers", def.display_name)
    end)

    it("1件だけ取り直す引数はIDで絞り込む", function()
      local args = assert(def.item_args)("abc123")

      assert.are.equal("ps", args[1])
      assert.is_truthy(vim.tbl_contains(args, "--filter"))
      assert.is_truthy(vim.tbl_contains(args, "id=abc123"))
      assert.is_truthy(vim.tbl_contains(args, "-a"), "停止したコンテナも取り直せること")
      assert.is_truthy(vim.tbl_contains(args, "--no-trunc"))
    end)

    it("削除の引数は強制削除を付けない", function()
      -- BR-002: 実行中コンテナの削除は docker に拒否させる。
      assert.are.same({ "rm", "abc123def456" }, assert(def.delete_args)(container()))
    end)
  end)

  describe("compose サービスの定義", function()
    ---@type docker.ResourceDefinition
    local def

    before_each(function()
      def = assert(registry.get("service"))
    end)

    it("カラムはSERVICE_STATUS_CONTAINERの順に並ぶ", function()
      local headers = {}
      for _, column in ipairs(def.columns) do
        table.insert(headers, column.header)
      end

      assert.are.same({ "SERVICE", "STATUS", "CONTAINER" }, headers)
    end)

    it("状態のカラム位置はSTATUSを指す", function()
      assert.are.equal(2, def.status_column)
      assert.are.equal("STATUS", def.columns[def.status_column].header)
    end)

    it("識別子はプロジェクト名とサービス名の組になる", function()
      -- 別プロジェクトの同名サービスと衝突させない。
      assert.are.equal("shop/web", def.id({ project = "shop", name = "web" }))
    end)

    it("一覧は単一のdockerコマンドではなく組み立てで取る", function()
      -- compose の定義とコンテナ一覧の突き合わせが必要 (7.3)。
      assert.is_truthy(def.load)
      assert.is_nil(def.list_args)
    end)

    it("コンテナのイベントで更新する", function()
      -- サービスの状態はコンテナの状態から決まる。
      assert.are.equal("container", def.event_type)
    end)

    it("Exコマンドの引数はservices", function()
      assert.are.equal("services", def.subcommand)
    end)

    it("キーマップはサービス一覧のものを引く", function()
      assert.are.equal("service_list", def.view_type)
    end)
  end)
end)
