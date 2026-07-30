local cli = require("docker.adapters.docker.cli")
local service_loader = require("docker.resources.service_loader")

describe("docker.resources.service_loader", function()
  local runs

  --- コンテナ一覧の 1 行 (ps の解析済みデータ)。
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
      compose_working_dir = "/work/shop",
    }, overrides or {})
  end

  ---@param items table[]
  ---@return string
  local function ndjson(items)
    local lines = {}
    for _, item in ipairs(items) do
      table.insert(lines, vim.json.encode(item))
    end
    return table.concat(lines, "\n")
  end

  --- コマンドの種類で応答を出し分ける偽の docker。
  --- responses:
  ---   ls        : { code, stdout } — `compose ls -a`
  ---   ps        : { code, stdout } — コンテナ一覧
  ---   cwd_config: { code, stdout, stderr } — `compose config` (プロジェクト名の指定なし)
  ---   config    : table<string, { code, stdout, stderr }> — `compose -p <name> config`
  local function stub(responses)
    cli._set_executor(function(cmd, opts, on_exit)
      table.insert(runs, { cmd = cmd, opts = opts })

      local function reply(out)
        on_exit({ code = out.code or 0, stdout = out.stdout or "", stderr = out.stderr or "" })
      end

      if cmd[2] == "ps" then
        return reply(responses.ps or { code = 0, stdout = "" })
      end
      if cmd[3] == "ls" then
        return reply(responses.ls or { code = 0, stdout = "[]" })
      end
      if cmd[3] == "-p" then
        local per_project = responses.config or {}
        return reply(per_project[cmd[4]] or { code = 1, stderr = "no configuration file provided: not found" })
      end
      return reply(responses.cwd_config or { code = 1, stderr = "no configuration file provided: not found" })
    end)
  end

  ---@param responses table
  ---@param cwd string|nil
  ---@return docker.ServiceLoadResult
  local function load(responses, cwd)
    stub(responses)
    local captured
    service_loader.load({
      cwd = cwd or "/elsewhere",
      container_args = { "ps", "-a", "--format", "{{json .}}" },
    }, function(result)
      captured = result
    end)
    return assert(captured, "on_done was not called")
  end

  ---@param items docker.Service[]
  ---@return string[]
  local function keys_of(items)
    local keys = {}
    for _, item in ipairs(items) do
      table.insert(keys, ("%s/%s=%s"):format(item.project, item.name, item.status))
    end
    return keys
  end

  before_each(function()
    runs = {}
  end)

  after_each(function()
    cli._set_executor(nil)
  end)

  describe("compose ファイルの無い場所からの一覧", function()
    it("ラベル由来のプロジェクトのサービスを一覧に出す", function()
      -- compose ファイルを読めなくても、コンテナのラベルからサービスを逆算できる。
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop","Status":"exited(1)","ConfigFiles":"/work/shop/compose.yaml"}]' },
        ps = { code = 0, stdout = ndjson({ container({ state = "exited" }) }) },
        config = {
          shop = { code = 0, stdout = '{"name":"shop","services":{"web":{},"never-started":{}}}' },
        },
      })

      assert.is_true(result.ok)
      assert.are.same({ "shop/never-started=none", "shop/web=exited" }, keys_of(result.data))
    end)

    it("compose ファイルのある場所を各行に持たせる", function()
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop","ConfigFiles":"/work/shop/compose.yaml"}]' },
        ps = { code = 0, stdout = ndjson({ container() }) },
        config = { shop = { code = 0, stdout = '{"name":"shop","services":{"web":{}}}' } },
      })

      assert.are.equal("/work/shop", result.data[1].working_dir)
    end)

    it("プロジェクトの定義はコンテナのラベルにある場所で引く", function()
      load({
        ls = { code = 0, stdout = '[{"Name":"shop","ConfigFiles":"/other/compose.yaml"}]' },
        ps = { code = 0, stdout = ndjson({ container({ compose_working_dir = "/work/shop" }) }) },
        config = { shop = { code = 0, stdout = '{"name":"shop","services":{"web":{}}}' } },
      })

      local config_run
      for _, run in ipairs(runs) do
        if run.cmd[3] == "-p" then
          config_run = run
        end
      end
      assert.are.same({ "docker", "compose", "-p", "shop", "config", "--format", "json" }, config_run.cmd)
      assert.are.equal("/work/shop", config_run.opts.cwd)
    end)

    it("ラベルに場所が無ければ設定ファイルのパスから場所を決める", function()
      -- 古い compose で working_dir ラベルが無い場合の受け皿。
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop","ConfigFiles":"/work/shop/compose.yaml"}]' },
        ps = { code = 0, stdout = ndjson({ container({ compose_working_dir = "" }) }) },
        config = { shop = { code = 0, stdout = '{"name":"shop","services":{"web":{}}}' } },
      })

      assert.are.equal("/work/shop", result.data[1].working_dir)
    end)

    it("設定ファイルが複数あるときは先頭の場所を使う", function()
      local result = load({
        ls = {
          code = 0,
          stdout = '[{"Name":"shop","ConfigFiles":"/work/shop/compose.yaml,/work/shop/compose.override.yaml"}]',
        },
        ps = { code = 0, stdout = ndjson({ container({ compose_working_dir = "" }) }) },
        config = { shop = { code = 0, stdout = '{"name":"shop","services":{"web":{}}}' } },
      })

      assert.are.equal("/work/shop", result.data[1].working_dir)
    end)
  end)

  describe("複数プロジェクトの統合", function()
    it("すべてのプロジェクトのサービスをまとめて出す", function()
      local result = load({
        ls = {
          code = 0,
          stdout = '[{"Name":"shop","ConfigFiles":"/work/shop/compose.yaml"},'
            .. '{"Name":"blog","ConfigFiles":"/work/blog/compose.yaml"}]',
        },
        ps = {
          code = 0,
          stdout = ndjson({
            container(),
            container({
              id = "b1",
              name = "blog-cms-1",
              compose_project = "blog",
              compose_service = "cms",
              compose_working_dir = "/work/blog",
            }),
          }),
        },
        config = {
          shop = { code = 0, stdout = '{"name":"shop","services":{"web":{}}}' },
          blog = { code = 0, stdout = '{"name":"blog","services":{"cms":{}}}' },
        },
      })

      assert.are.same({ "blog/cms=running", "shop/web=running" }, keys_of(result.data))
    end)

    it("作業ディレクトリのプロジェクトを合流させる", function()
      -- 一度も起動していないプロジェクトはラベルに現れないので、ここでしか拾えない。
      local result = load({
        ls = { code = 0, stdout = "[]" },
        ps = { code = 0, stdout = "" },
        cwd_config = { code = 0, stdout = '{"name":"fresh","services":{"web":{},"db":{}}}' },
      }, "/work/fresh")

      assert.is_true(result.ok)
      assert.are.same({ "fresh/db=none", "fresh/web=none" }, keys_of(result.data))
      assert.are.equal("/work/fresh", result.data[1].working_dir)
    end)

    it("作業ディレクトリのプロジェクトがラベルにもあるとき二重に出さない", function()
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop","ConfigFiles":"/work/shop/compose.yaml"}]' },
        ps = { code = 0, stdout = ndjson({ container() }) },
        cwd_config = { code = 0, stdout = '{"name":"shop","services":{"web":{},"never-started":{}}}' },
      }, "/work/shop")

      assert.are.same({ "shop/never-started=none", "shop/web=running" }, keys_of(result.data))
    end)

    it("作業ディレクトリがプロジェクト外でも一覧を返す", function()
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop","ConfigFiles":"/work/shop/compose.yaml"}]' },
        ps = { code = 0, stdout = ndjson({ container() }) },
        cwd_config = { code = 1, stderr = "no configuration file provided: not found" },
        config = { shop = { code = 0, stdout = '{"name":"shop","services":{"web":{}}}' } },
      })

      assert.is_true(result.ok)
      assert.is_nil(result.warning)
      assert.are.same({ "shop/web=running" }, keys_of(result.data))
    end)

    it("プロジェクトが1つも無ければ空の一覧を返す", function()
      local result = load({ ls = { code = 0, stdout = "[]" }, ps = { code = 0, stdout = "" } })

      assert.is_true(result.ok)
      assert.are.same({}, result.data)
    end)
  end)

  describe("定義を引けないプロジェクト", function()
    it("compose ファイルが読めなければコンテナのあるサービスだけ出す", function()
      -- working_dir が消えているプロジェクト。起動していないサービスは分からない。
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop","ConfigFiles":"/gone/compose.yaml"}]' },
        ps = { code = 0, stdout = ndjson({ container({ compose_working_dir = "/gone" }) }) },
        config = { shop = { code = 1, stderr = "no configuration file provided: not found" } },
      })

      assert.is_true(result.ok)
      assert.are.same({ "shop/web=running" }, keys_of(result.data))
    end)

    it("場所が分からないプロジェクトでは定義を引きにいかない", function()
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop"}]' },
        ps = { code = 0, stdout = ndjson({ container({ compose_working_dir = "" }) }) },
      })

      local issued = {}
      for _, run in ipairs(runs) do
        table.insert(issued, table.concat(run.cmd, " "))
      end
      table.sort(issued)
      assert.are.same({
        "docker compose config --format json",
        "docker compose ls -a --format json",
        "docker ps -a --format {{json .}}",
      }, issued)
      assert.are.same({ "shop/web=running" }, keys_of(result.data))
      assert.are.equal("", result.data[1].working_dir)
    end)

    it("単発コンテナしか無いプロジェクトはサービスを持たない", function()
      -- BR-006: `docker compose run` のコンテナはサービスの実体ではない。
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop"}]' },
        ps = {
          code = 0,
          stdout = ndjson({
            container({ name = "shop-web-run-abc", compose_oneoff = "True", compose_working_dir = "" }),
          }),
        },
      })

      assert.is_true(result.ok)
      assert.are.same({}, result.data)
    end)
  end)

  describe("失敗の扱い", function()
    it("composeサブコマンドが使えなければ一覧を返さない", function()
      local result = load({
        ls = { code = 1, stderr = "docker: unknown command: docker compose" },
        ps = { code = 0, stdout = "" },
      })

      assert.is_false(result.ok)
      assert.are.equal(
        "docker compose サブコマンドが使えません。compose プラグインの導入を確認してください。",
        result.error
      )
    end)

    it("コンテナ一覧の取得に失敗したら一覧を返さない", function()
      local result = load({
        ls = { code = 0, stdout = "[]" },
        ps = { code = 1, stderr = "Cannot connect to the Docker daemon" },
      })

      assert.is_false(result.ok)
      assert.are.equal("Cannot connect to the Docker daemon", result.error)
    end)

    it("作業ディレクトリのcomposeファイルが不正なら警告を添えて一覧を返す", function()
      -- 他のプロジェクトは見えるので一覧そのものは出す (BR-016: 文言はそのまま)。
      local stderr = "yaml: mapping values are not allowed in this context"
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop","ConfigFiles":"/work/shop/compose.yaml"}]' },
        ps = { code = 0, stdout = ndjson({ container() }) },
        cwd_config = { code = 1, stderr = stderr },
        config = { shop = { code = 0, stdout = '{"name":"shop","services":{"web":{}}}' } },
      })

      assert.is_true(result.ok)
      assert.are.equal(stderr, result.warning)
      assert.are.same({ "shop/web=running" }, keys_of(result.data))
    end)
  end)
end)
