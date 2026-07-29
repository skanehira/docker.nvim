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
      assert.are.same({ "containers", "images", "volumes", "networks", "services" }, registry.subcommands())
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

  describe("イメージ・ボリューム・ネットワークの定義", function()
    it("イメージの一覧と削除の引数", function()
      local def = assert(registry.get("image"))

      local args = assert(def.list_args)()
      assert.are.same({ "image", "ls" }, { args[1], args[2] })
      assert.is_truthy(vim.tbl_contains(args, "--no-trunc"))
      -- `docker image ls` は .Label を扱えない。
      assert.is_nil(table.concat(args, " "):find(".Label", 1, true))

      -- イベントの Actor.ID (sha) は識別子 (タグ参照) と対応しないので全件取り直す。
      -- `docker image ls` は id フィルタも受け付けない (invalid filter 'id')。
      assert.is_nil(def.item_args, "1 件だけの取り直しは使わない")
      assert.is_true(def.event_reload)

      -- 同じイメージに複数タグが付くため、識別子はタグ参照にする。
      assert.are.equal("alpine:3.20", def.id({ id = "i1", repository = "alpine", tag = "3.20" }))
      assert.are.equal("i1", def.id({ id = "i1", repository = "<none>", tag = "<none>" }))
      -- 同じイメージに複数タグがあるとき、ID で消すとイメージ本体が対象になり
      -- 他のタグで使われていると削除できない。タグがあればタグ参照を使う。
      assert.are.same(
        { "rmi", "alpine:3.20" },
        assert(def.delete_args)({ id = "img1", repository = "alpine", tag = "3.20" })
      )
      assert.are.same(
        { "rmi", "img1" },
        assert(def.delete_args)({ id = "img1", repository = "<none>", tag = "<none>" }),
        "タグが無いイメージは ID で消す"
      )
    end)

    it("イメージのカラム構成と値", function()
      local def = assert(registry.get("image"))
      local item = { id = "i1", repository = "alpine", tag = "3.20", size = "5MB", created_since = "2 days ago" }

      local values = {}
      for _, column in ipairs(def.columns) do
        table.insert(values, { column.header, column.value(item) })
      end

      assert.are.same({
        { "REPOSITORY", "alpine" },
        { "TAG", "3.20" },
        { "SIZE", "5MB" },
        { "CREATED", "2 days ago" },
      }, values)
    end)

    it("ボリューム・ネットワークのカラム構成と値", function()
      local volume = assert(registry.get("volume"))
      local vvalues = {}
      for _, column in ipairs(volume.columns) do
        table.insert(vvalues, { column.header, column.value({ name = "v1", driver = "local", mountpoint = "/m" }) })
      end
      assert.are.same({ { "NAME", "v1" }, { "DRIVER", "local" }, { "MOUNTPOINT", "/m" } }, vvalues)

      local network = assert(registry.get("network"))
      local nvalues = {}
      for _, column in ipairs(network.columns) do
        table.insert(
          nvalues,
          { column.header, column.value({ id = "n1", name = "bridge", driver = "bridge", scope = "local" }) }
        )
      end
      assert.are.same({ { "NAME", "bridge" }, { "DRIVER", "bridge" }, { "SCOPE", "local" } }, nvalues)
    end)

    it("ボリュームの一覧と削除の引数", function()
      local def = assert(registry.get("volume"))

      local args = assert(def.list_args)()
      -- 書式を渡さないと docker の既定の表形式になり、解析できなくなる。
      assert.are.same({
        "volume",
        "ls",
        "--format",
        '{"name":{{json .Name}},"driver":{{json .Driver}},"mountpoint":{{json .Mountpoint}}}',
      }, args)
      -- ボリュームは名前が識別子 (イベントでも Actor.ID に名前が入る)。
      assert.are.equal("vol1", def.id({ name = "vol1" }))
      assert.are.same({ "volume", "rm", "vol1" }, assert(def.delete_args)({ name = "vol1" }))
    end)

    it("ネットワークの一覧と削除の引数", function()
      local def = assert(registry.get("network"))

      local args = assert(def.list_args)()
      assert.are.same({
        "network",
        "ls",
        "--no-trunc",
        "--format",
        '{"id":{{json .ID}},"name":{{json .Name}},"driver":{{json .Driver}},"scope":{{json .Scope}}}',
      }, args)
      assert.are.same({ "network", "rm", "net1" }, assert(def.delete_args)({ id = "net1" }))
    end)

    it("組み込みネットワークを削除対象から除外しない", function()
      -- 削除の可否は docker に判断させ、エラーをそのまま提示する (BR-016)。
      local def = assert(registry.get("network"))

      assert.are.same({ "network", "rm", "bridge" }, assert(def.delete_args)({ id = "bridge", name = "bridge" }))
    end)

    it("それぞれのイベント種別に対応付く", function()
      assert.are.equal("image", assert(registry.get("image")).event_type)
      assert.are.equal("volume", assert(registry.get("volume")).event_type)
      assert.are.equal("network", assert(registry.get("network")).event_type)
    end)

    it("状態カラムを持たない", function()
      -- コンテナやサービスと違い、状態という概念が無い。
      for _, kind in ipairs({ "image", "volume", "network" }) do
        assert.is_nil(assert(registry.get(kind)).status_column, kind)
      end
    end)
  end)

  describe("0 件表示", function()
    it("種別ごとに項目が無いことを示す文言を持つ", function()
      local texts = {}
      for _, kind in ipairs({ "container", "image", "volume", "network", "service" }) do
        texts[kind] = assert(registry.get(kind)).empty_text
      end

      assert.are.same({
        container = "コンテナがありません",
        image = "イメージがありません",
        volume = "ボリュームがありません",
        network = "ネットワークがありません",
        service = "サービスが定義されていません",
      }, texts)
    end)
  end)
end)
