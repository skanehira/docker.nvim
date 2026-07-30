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

  --- コマンドの種類を表す名前。応答の指定と、返す順序の指定に使う。
  ---@param cmd string[]
  ---@return "ps"|"ls"|"config"|"cwd_config"
  local function kind_of(cmd)
    if cmd[2] == "ps" then
      return "ps"
    end
    if cmd[3] == "ls" then
      return "ls"
    end
    if cmd[3] == "-p" then
      return "config"
    end
    return "cwd_config"
  end

  ---@param responses table
  ---@param cmd string[]
  ---@return table
  local function response_for(responses, cmd)
    local kind = kind_of(cmd)
    if kind == "ps" then
      return responses.ps or { code = 0, stdout = "" }
    end
    if kind == "ls" then
      return responses.ls or { code = 0, stdout = "[]" }
    end
    if kind == "config" then
      local per_project = responses.config or {}
      return per_project[cmd[4]] or { code = 1, stderr = "no configuration file provided: not found" }
    end
    return responses.cwd_config or { code = 1, stderr = "no configuration file provided: not found" }
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
      local out = response_for(responses, cmd)
      on_exit({ code = out.code or 0, stdout = out.stdout or "", stderr = out.stderr or "" })
    end)
  end

  --- 応答を保留し、任意の順序で返せる偽の docker。
  --- docker の応答が返る順序は発行順とは限らないので、順序を変えても結果が変わらないことを見る。
  ---@param responses table
  ---@return { flush: fun(kind: string), pending: fun(): string[] }
  local function deferred_stub(responses)
    local queue = {}
    cli._set_executor(function(cmd, opts, on_exit)
      table.insert(runs, { cmd = cmd, opts = opts })
      table.insert(queue, {
        kind = kind_of(cmd),
        deliver = function()
          local out = response_for(responses, cmd)
          on_exit({ code = out.code or 0, stdout = out.stdout or "", stderr = out.stderr or "" })
        end,
      })
    end)

    return {
      --- 保留中の応答から、指定した種類のものを 1 つ返す。
      flush = function(kind)
        for index, entry in ipairs(queue) do
          if entry.kind == kind then
            table.remove(queue, index)
            entry.deliver()
            return
          end
        end
        error("保留中の応答が無い: " .. kind)
      end,
      pending = function()
        local kinds = {}
        for _, entry in ipairs(queue) do
          table.insert(kinds, entry.kind)
        end
        return kinds
      end,
    }
  end

  ---@param responses table
  ---@param cwd string|nil
  ---@return docker.ServiceLoadResult
  local function load(responses, cwd)
    stub(responses)
    local captured, calls = nil, 0
    service_loader.load({
      cwd = cwd or "/elsewhere",
      container_args = { "ps", "-a", "--format", "{{json .}}" },
    }, function(result)
      captured, calls = result, calls + 1
    end)
    -- 多段の非同期では、経路によって完了が二重に走る形の壊れ方をする。
    assert.are.equal(1, calls)
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
      assert.are.same({
        {
          project = "shop",
          name = "never-started",
          container = "",
          container_id = "",
          status = "none",
          working_dir = "/work/shop",
        },
        {
          project = "shop",
          name = "web",
          container = "shop-web-1",
          container_id = "abc123",
          status = "exited",
          working_dir = "/work/shop",
        },
      }, result.data)
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

    it("同じプロジェクトに場所を持たないコンテナが混じっていても場所を拾う", function()
      -- 古い compose が作ったコンテナにはラベルが無い。1 件目で諦めない。
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop"}]' },
        ps = {
          code = 0,
          stdout = ndjson({
            container({ id = "old", name = "shop-web-1", compose_working_dir = "" }),
            container({ id = "new", name = "shop-web-2", compose_working_dir = "/work/shop" }),
          }),
        },
        config = { shop = { code = 0, stdout = '{"name":"shop","services":{"web":{}}}' } },
      })

      assert.are.equal("/work/shop", result.data[1].working_dir)
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

    it("作業ディレクトリで開いたプロジェクトの場所はラベルより優先する", function()
      -- プロジェクトを別の場所へ移して起動前の状態。ラベルは移動前の場所を指したままなので、
      -- 今いる場所を採らないと起動が古い定義で走る。
      local result = load({
        ls = { code = 0, stdout = '[{"Name":"shop","ConfigFiles":"/work/shop/compose.yaml"}]' },
        ps = { code = 0, stdout = ndjson({ container({ compose_working_dir = "/work/shop" }) }) },
        cwd_config = { code = 0, stdout = '{"name":"shop","services":{"web":{}}}' },
      }, "/work/shop-moved")

      assert.are.equal("/work/shop-moved", result.data[1].working_dir)
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

  describe("応答が返る順序", function()
    local RESPONSES = {
      ls = { code = 0, stdout = '[{"Name":"shop","ConfigFiles":"/work/shop/compose.yaml"}]' },
      ps = { code = 0, stdout = ndjson({ container() }) },
      cwd_config = { code = 1, stderr = "no configuration file provided: not found" },
      config = { shop = { code = 0, stdout = '{"name":"shop","services":{"web":{},"never-started":{}}}' } },
    }

    --- 指定した順序で応答を返し、組み上がった一覧を得る。
    ---@param order string[] 先に返す順に並べた種類 ("ls" / "ps" / "cwd_config")
    ---@return docker.ServiceLoadResult
    ---@return string[] 最後の 1 つを返す前の時点で、まだ完了していないことの記録
    local function load_in_order(order)
      local stubbed = deferred_stub(RESPONSES)
      local captured
      service_loader.load({
        cwd = "/elsewhere",
        container_args = { "ps", "-a", "--format", "{{json .}}" },
      }, function(result)
        captured = result
      end)

      local seen_before_last = {}
      for index, kind in ipairs(order) do
        if index == #order then
          seen_before_last = keys_of(captured and captured.data or {})
        end
        stubbed.flush(kind)
      end
      -- 定義の取得はここまでの応答が揃ってから発行される。残りをすべて返す。
      while #stubbed.pending() > 0 do
        stubbed.flush(stubbed.pending()[1])
      end

      return assert(captured, "on_done was not called"), seen_before_last
    end

    it("最後の1つが返るまで一覧を組み立てない", function()
      -- 揃う前に組み立てると、まだ取れていないコンテナ一覧を 0 件として扱ってしまう。
      local result, before_last = load_in_order({ "ls", "cwd_config", "ps" })

      assert.are.same({}, before_last)
      assert.are.same({ "shop/never-started=none", "shop/web=running" }, keys_of(result.data))
    end)

    it("返る順序が変わっても同じ一覧になる", function()
      local forward = load_in_order({ "ls", "ps", "cwd_config" })
      local reversed = load_in_order({ "cwd_config", "ps", "ls" })

      assert.are.same(forward.data, reversed.data)
      assert.are.same({ "shop/never-started=none", "shop/web=running" }, keys_of(reversed.data))
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
