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
    it("composeプロジェクト外だとわかるメッセージを返す", function()
      -- 実機 (compose v5.1.2) の文言。
      stub({ code = 1, stderr = "no configuration file provided: not found" })

      local result = resolve()

      assert.is_false(result.ok)
      assert.are.equal("outside", result.reason)
      assert.are.equal(
        "ここは docker compose プロジェクトではありません。compose.yaml のあるディレクトリで開いてください。",
        result.error
      )
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

    it("3つの失敗はそれぞれ異なる区分になる", function()
      -- G11: compose サブコマンド不在が他と区別できること。
      local reasons, seen = {}, {}
      local messages_differ = true
      for _, stderr in ipairs({
        "no configuration file provided: not found",
        "docker: unknown command: docker compose",
        "yaml: mapping values are not allowed in this context",
      }) do
        stub({ code = 1, stderr = stderr })
        local result = resolve()
        table.insert(reasons, result.reason)
        if seen[result.error] then
          messages_differ = false
        end
        seen[result.error] = true
      end

      assert.are.same({ "outside", "unavailable", "invalid" }, reasons)
      -- 区分だけでなく、利用者に見える文言も取り違えていないこと。
      assert.is_true(messages_differ, "3 つの文言がすべて異なること")
    end)

    it("出力が解析できないときは不正として扱う", function()
      stub({ code = 0, stdout = "not json" })

      assert.are.equal("invalid", resolve().reason)
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
