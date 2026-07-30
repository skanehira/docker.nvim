local cli = require("docker.adapters.docker.cli")
local compose = require("docker.adapters.docker.compose")

describe("docker.adapters.docker.compose", function()
  local runs

  --- 与えた終了状態を返す偽の docker。
  local function stub(out)
    cli._set_executor(function(cmd, opts, on_exit)
      table.insert(runs, { cmd = cmd, opts = opts })
      on_exit({ code = out.code, stdout = out.stdout or "", stderr = out.stderr or "" })
    end)
  end

  ---@return docker.ComposeResult
  local function resolve(cwd)
    local captured
    compose.resolve_project(cwd or "/proj", function(result)
      captured = result
    end)
    return assert(captured, "on_done was not called")
  end

  before_each(function()
    runs = {}
  end)

  after_each(function()
    cli._set_executor(nil)
  end)

  describe("resolve_project", function()
    it("設定をJSONで取得する引数でdocker composeを呼ぶ", function()
      -- `config --services` は出力順が実行のたびに変わるため使わない。
      stub({ code = 0, stdout = '{"name":"shop","services":{}}' })

      resolve()

      assert.are.same({ "docker", "compose", "config", "--format", "json" }, runs[1].cmd)
    end)

    it("ビューを開いた時点の作業ディレクトリで実行する", function()
      -- BR-003: compose の解決はカレントディレクトリに依存する。
      stub({ code = 0, stdout = '{"name":"shop","services":{}}' })

      resolve("/work/shop")

      assert.are.equal("/work/shop", runs[1].opts.cwd)
    end)

    it("プロジェクト名とサービス全件を取り出す", function()
      stub({
        code = 0,
        stdout = '{"name":"shop","services":{"web":{},"worker":{},"db":{}},"networks":{}}',
      })

      local result = resolve("/work/shop")

      assert.is_true(result.ok)
      assert.are.equal("shop", result.data.name)
      assert.are.equal("/work/shop", result.data.working_dir)
      assert.are.same({ "db", "web", "worker" }, result.data.service_names)
    end)

    it("サービス名は常に同じ順序で返す", function()
      -- JSON オブジェクトのキー順は保証されない。行順が実行のたびに変わらないよう並べる。
      stub({ code = 0, stdout = '{"name":"shop","services":{"zeta":{},"alpha":{},"mid":{}}}' })

      assert.are.same({ "alpha", "mid", "zeta" }, resolve().data.service_names)
    end)

    it("起動していないサービスも含めて返す", function()
      stub({ code = 0, stdout = '{"name":"shop","services":{"web":{},"never-started":{}}}' })

      assert.are.same({ "never-started", "web" }, resolve().data.service_names)
    end)

    it("サービスが0件でも成功として扱う", function()
      stub({ code = 0, stdout = '{"name":"shop","services":{}}' })

      local result = resolve()

      assert.is_true(result.ok)
      assert.are.same({}, result.data.service_names)
    end)
  end)

  describe("3つの失敗を区別する", function()
    it("composeプロジェクト外だとわかる区分を返す", function()
      -- 実機 (compose v5.1.2) の文言。
      -- プロジェクト外は正常系として扱うので、独自の案内文は持たせない。
      stub({ code = 1, stderr = "no configuration file provided: not found" })

      local result = resolve()

      assert.is_false(result.ok)
      assert.are.equal("outside", result.reason)
      assert.are.equal("no configuration file provided: not found", result.error)
    end)

    it("composeサブコマンドが使えないとわかるメッセージを返す", function()
      -- docker 29 は "unknown command"、それ以前は "'compose' is not a docker command"。
      local messages = {}
      for _, stderr in ipairs({
        "docker: unknown command: docker compose",
        "docker: 'compose' is not a docker command.",
      }) do
        stub({ code = 1, stderr = stderr })
        local result = resolve()
        assert.are.equal("unavailable", result.reason)
        table.insert(messages, result.error)
      end

      assert.are.same({
        "docker compose サブコマンドが使えません。compose プラグインの導入を確認してください。",
        "docker compose サブコマンドが使えません。compose プラグインの導入を確認してください。",
      }, messages)
    end)

    it("composeファイルが不正なときはdockerの出力をそのまま返す", function()
      local stderr = "yaml: while parsing a flow sequence at line 2, column 12: did not find expected ',' or ']'"
      stub({ code = 1, stderr = stderr })

      local result = resolve()

      assert.are.equal("invalid", result.reason)
      assert.are.equal(stderr, result.error)
    end)

    it("3つの失敗はそれぞれ異なる区分と文言になる", function()
      -- G11: compose サブコマンド不在が他と区別できること。
      local outcomes = {}
      for _, stderr in ipairs({
        "no configuration file provided: not found",
        "docker: unknown command: docker compose",
        "yaml: mapping values are not allowed in this context",
      }) do
        stub({ code = 1, stderr = stderr })
        local result = resolve()
        table.insert(outcomes, { reason = result.reason, message = result.error })
      end

      -- 区分だけでなく、利用者に見える文言も取り違えていないこと。
      assert.are.same({
        { reason = "outside", message = "no configuration file provided: not found" },
        {
          reason = "unavailable",
          message = "docker compose サブコマンドが使えません。compose プラグインの導入を確認してください。",
        },
        { reason = "invalid", message = "yaml: mapping values are not allowed in this context" },
      }, outcomes)
    end)

    it("出力が解析できないときは不正として扱う", function()
      stub({ code = 0, stdout = "not json" })

      assert.are.equal("invalid", resolve().reason)
    end)
  end)

  describe("list_projects", function()
    ---@return docker.ComposeResult
    local function list()
      local captured
      compose.list_projects(function(result)
        captured = result
      end)
      return assert(captured, "on_done was not called")
    end

    it("停止中を含む全プロジェクトをJSONで取得する引数でdocker composeを呼ぶ", function()
      -- `-a` が無いと稼働中のプロジェクトしか出ず、停止したプロジェクトが一覧から消える。
      stub({ code = 0, stdout = "[]" })

      list()

      assert.are.same({ "docker", "compose", "ls", "-a", "--format", "json" }, runs[1].cmd)
    end)

    it("どの作業ディレクトリにも依存せず実行する", function()
      -- プロジェクトの列挙はラベル由来で、compose ファイルの場所に依存しない。
      stub({ code = 0, stdout = "[]" })

      list()

      assert.is_nil(runs[1].opts.cwd)
    end)

    it("プロジェクト名と設定ファイルのパスを取り出す", function()
      stub({
        code = 0,
        stdout = '[{"Name":"shop","Status":"running(2)","ConfigFiles":"/work/shop/compose.yaml"},'
          .. '{"Name":"blog","Status":"exited(1)","ConfigFiles":"/work/blog/compose.yaml"}]',
      })

      local result = list()

      assert.is_true(result.ok)
      assert.are.same({
        { name = "shop", config_files = "/work/shop/compose.yaml" },
        { name = "blog", config_files = "/work/blog/compose.yaml" },
      }, result.data)
    end)

    it("プロジェクトが0件でも成功として扱う", function()
      stub({ code = 0, stdout = "[]" })

      local result = list()

      assert.is_true(result.ok)
      assert.are.same({}, result.data)
    end)

    it("設定ファイルのパスが無いプロジェクトは空文字列にする", function()
      stub({ code = 0, stdout = '[{"Name":"shop","Status":"running(1)"}]' })

      assert.are.same({ { name = "shop", config_files = "" } }, list().data)
    end)

    it("composeサブコマンドが使えないとわかるメッセージを返す", function()
      stub({ code = 1, stderr = "docker: unknown command: docker compose" })

      local result = list()

      assert.is_false(result.ok)
      assert.are.equal("unavailable", result.reason)
      assert.are.equal(
        "docker compose サブコマンドが使えません。compose プラグインの導入を確認してください。",
        result.error
      )
    end)

    it("出力が解析できないときは不正として扱う", function()
      stub({ code = 0, stdout = "not json" })

      local result = list()

      assert.is_false(result.ok)
      assert.are.equal("invalid", result.reason)
    end)
  end)

  describe("既存プロジェクトの定義の補完", function()
    it("プロジェクト名を指定すると-pを付けて実行する", function()
      -- ディレクトリ名から決まる既定のプロジェクト名と、コンテナのラベルにある
      -- プロジェクト名は COMPOSE_PROJECT_NAME や -p 起動でずれる。名指しして取り違えを防ぐ。
      stub({ code = 0, stdout = '{"name":"shop","services":{"web":{}}}' })

      local captured
      compose.resolve_project("/work/shop", function(result)
        captured = result
      end, { project_name = "shop" })

      assert.are.same({ "docker", "compose", "-p", "shop", "config", "--format", "json" }, runs[1].cmd)
      assert.are.equal("/work/shop", runs[1].opts.cwd)
      assert.are.same({ "web" }, captured.data.service_names)
    end)
  end)

  describe("run", function()
    it("compose のサブコマンドを作業ディレクトリで実行する", function()
      stub({ code = 0, stdout = "" })

      compose.run({ "up", "-d", "web" }, "/work/shop", function() end)

      assert.are.same({ "docker", "compose", "up", "-d", "web" }, runs[1].cmd)
      assert.are.equal("/work/shop", runs[1].opts.cwd)
    end)

    it("失敗するとdockerの標準エラー出力をそのまま返す", function()
      stub({ code = 1, stderr = 'service "nope" is not defined' })

      local captured
      compose.run({ "up", "-d", "nope" }, "/work", function(result)
        captured = result
      end)

      assert.is_false(captured.ok)
      assert.are.equal('service "nope" is not defined', captured.error)
    end)
  end)
end)
