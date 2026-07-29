local cli = require("docker.adapters.docker.cli")
local notify = require("docker.notify")

describe("docker.adapters.docker.cli", function()
  local calls

  --- 与えた終了状態を返す偽の実行器を仕込む。
  ---@param out { code: integer, stdout: string|nil, stderr: string|nil }
  local function stub_executor(out)
    cli._set_executor(function(cmd, opts, on_exit)
      table.insert(calls, { cmd = cmd, opts = opts })
      on_exit({ code = out.code, stdout = out.stdout or "", stderr = out.stderr or "" })
    end)
  end

  ---@return docker.Result
  local function run_sync(args, opts)
    local captured
    cli.run(args, function(result)
      captured = result
    end, opts)
    return assert(captured, "on_done was not called")
  end

  before_each(function()
    calls = {}
  end)

  after_each(function()
    cli._set_executor(nil)
    notify.set_debug(false)
  end)

  describe("run", function()
    it("引数の先頭にdockerを付けて実行器へ渡す", function()
      stub_executor({ code = 0, stdout = "" })

      run_sync({ "ps", "-a" })

      assert.are.same({ "docker", "ps", "-a" }, calls[1].cmd)
    end)

    it("終了コード0のとき成否が真で標準出力がそのままdataに入る", function()
      stub_executor({ code = 0, stdout = "hello\n" })

      assert.are.same({ ok = true, data = "hello\n", error = nil, code = 0 }, run_sync({ "version" }))
    end)

    it("parseにndjsonを指定すると解析済みのテーブルがdataに入る", function()
      stub_executor({ code = 0, stdout = '{"id":"a"}\n{"id":"b"}\n' })

      assert.are.same(
        { ok = true, data = { { id = "a" }, { id = "b" } }, error = nil, code = 0 },
        run_sync({ "ps" }, { parse = "ndjson" })
      )
    end)

    it("parseにjsonを指定すると単一のJSONを解析してdataに入れる", function()
      stub_executor({ code = 0, stdout = '{"name":"bridge"}' })

      assert.are.same(
        { ok = true, data = { name = "bridge" }, error = nil, code = 0 },
        run_sync({ "inspect", "bridge" }, { parse = "json" })
      )
    end)

    it("終了コードが非0のとき成否が偽で標準エラー出力がそのままerrorに入る", function()
      stub_executor({ code = 1, stderr = "Error response from daemon: conflict\n" })

      assert.are.same(
        { ok = false, data = nil, error = "Error response from daemon: conflict", code = 1 },
        run_sync({ "rm", "web" })
      )
    end)

    it(
      "失敗時に標準エラー出力が空なら終了コードを含む既定のメッセージを返す",
      function()
        stub_executor({ code = 125, stderr = "" })

        assert.are.same(
          { ok = false, data = nil, error = "docker exited with code 125", code = 125 },
          run_sync({ "start", "web" })
        )
      end
    )

    it("成功しても解析できない出力ならエラーとして返す", function()
      stub_executor({ code = 0, stdout = "not json" })

      assert.are.same({
        ok = false,
        data = nil,
        error = "failed to parse docker output",
        code = 0,
      }, run_sync({ "inspect", "web" }, { parse = "json" }))
    end)

    it("parseにjsonを指定してオブジェクトでない出力ならエラーとして返す", function()
      -- `{{json .X}}` は値の無いフィールドに null を出すため、実際に起こりうる。
      -- 呼び出し側が data をテーブルとして扱えるようここで弾く。
      for _, stdout in ipairs({ "null", "123", '"text"', "true" }) do
        stub_executor({ code = 0, stdout = stdout })

        assert.are.same({
          ok = false,
          data = nil,
          error = "failed to parse docker output",
          code = 0,
        }, run_sync({ "inspect", "web" }, { parse = "json" }), "入力: " .. stdout)
      end
    end)

    it("cwdを指定すると実行器のオプションに渡る", function()
      stub_executor({ code = 0, stdout = "" })

      run_sync({ "compose", "ps" }, { cwd = "/tmp/proj" })

      assert.are.equal("/tmp/proj", calls[1].opts.cwd)
    end)

    it("完了コールバックはちょうど1回だけ呼ばれる", function()
      stub_executor({ code = 0, stdout = "ok" })

      local count = 0
      cli.run({ "ps" }, function()
        count = count + 1
      end)

      assert.are.equal(1, count)
    end)

    it("終了コードを報告しない実行結果はエラーとして返す", function()
      cli._set_executor(function(_, _, on_exit)
        on_exit({ stdout = "", stderr = "" })
      end)

      assert.are.same({
        ok = false,
        data = nil,
        error = "docker did not report an exit code",
        code = nil,
      }, run_sync({ "ps" }))
    end)

    it("ndjsonで全行が解析できないときは0件ではなくエラーとして返す", function()
      stub_executor({ code = 0, stdout = "broken\nalso broken\n" })

      assert.are.same({
        ok = false,
        data = nil,
        error = "failed to parse all 2 line(s) of docker output",
        code = 0,
      }, run_sync({ "ps" }, { parse = "ndjson" }))
    end)

    it("ndjsonで一部の行だけ解析できないときは解析できた分を返す", function()
      stub_executor({ code = 0, stdout = '{"id":"a"}\nbroken\n' })

      assert.are.same(
        { ok = true, data = { { id = "a" } }, error = nil, code = 0 },
        run_sync({ "ps" }, { parse = "ndjson" })
      )
    end)

    it("シグナルで終了したときは終了コードが0でも失敗として返す", function()
      -- vim.system はシグナルで殺されたプロセスに code=0, signal=15 を返す。
      -- 成功として扱うと、途中で切れた出力を「全件」と解釈してしまう。
      cli._set_executor(function(_, _, on_exit)
        on_exit({ code = 0, signal = 15, stdout = '{"id":"a"}\n', stderr = "" })
      end)

      assert.are.same({
        ok = false,
        data = nil,
        error = "docker was terminated by signal 15",
        code = 0,
      }, run_sync({ "ps" }, { parse = "ndjson" }))
    end)

    it("正常終了のsignal0は成功として扱う", function()
      cli._set_executor(function(_, _, on_exit)
        on_exit({ code = 0, signal = 0, stdout = "ok", stderr = "" })
      end)

      assert.are.same({ ok = true, data = "ok", error = nil, code = 0 }, run_sync({ "ps" }))
    end)

    it("リトライせず実行器をちょうど1回だけ呼ぶ", function()
      -- 副作用のある操作を自動再試行しない (8.2)。
      stub_executor({ code = 1, stderr = "boom" })

      run_sync({ "start", "web" })

      assert.are.equal(1, #calls)
    end)
  end)

  describe("fast event context での配送", function()
    it(
      "実行器がfast_event内で完了を通知しても結果を配送しデバッグ通知も落ちない",
      function()
        -- vim.system の on_exit は fast event context で呼ばれ、そこでは vim.notify が
        -- E5560 で失敗する。アダプタ層で吸収していないと on_done が一度も呼ばれない。
        notify.set_debug(true)
        cli._set_executor(function(_, _, on_exit)
          -- 実際に fast event context を作るため、docker とは無関係の外部プロセスを使う。
          vim.system({ "sh", "-c", "exit 0" }, { text = true }, function()
            assert(vim.in_fast_event(), "この経路は fast event context である前提")
            on_exit({ code = 0, stdout = "delivered", stderr = "" })
          end)
        end)

        local captured
        cli.run({ "ps" }, function(result)
          captured = result
        end)

        local ok = vim.wait(3000, function()
          return captured ~= nil
        end)

        assert.is_true(ok, "on_done が呼ばれること (fast event で握り潰されていないこと)")
        assert.are.same({ ok = true, data = "delivered", error = nil, code = 0 }, captured)
      end
    )
  end)

  describe("既定の実行器", function()
    local original_system

    --- 既定の実行器は起動失敗も次のイベントループで返すため、待ってから検証する。
    ---@return docker.Result
    local function run_async(args, opts)
      local captured
      cli.run(args, function(result)
        captured = result
      end, opts)
      local ok = vim.wait(3000, function()
        return captured ~= nil
      end)
      assert(ok, "on_done が呼ばれなかった")
      return captured
    end

    before_each(function()
      cli._set_executor(nil)
      original_system = vim.system
    end)

    after_each(function()
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.system = original_system
    end)

    it("起動に失敗しても結果は同じイベントループ内では配送されない", function()
      -- 起動失敗だけ同期で返すと、先に発行した実行より後から発行した失敗が
      -- 先に配送され、呼び出し順と配送順が入れ替わる。
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.system = function()
        error("ENOENT: no such file or directory")
      end

      local delivered = false
      cli.run({ "ps" }, function()
        delivered = true
      end)

      assert.is_false(delivered, "cli.run の内側で on_done が呼ばれていないこと")

      vim.wait(3000, function()
        return delivered
      end)
      assert.is_true(delivered, "その後のイベントループで配送されること")
    end)

    it("コマンドと実在するcwdをvim_systemへそのまま渡す", function()
      local cwd = vim.fn.getcwd()
      local passed
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.system = function(cmd, opts, on_exit)
        passed = { cmd = cmd, opts = opts }
        on_exit({ code = 0, stdout = "out", stderr = "" })
      end

      local result = run_async({ "ps", "-a" }, { cwd = cwd })

      assert.are.same({ "docker", "ps", "-a" }, passed.cmd)
      assert.are.equal(cwd, passed.opts.cwd)
      assert.are.same({ ok = true, data = "out", error = nil, code = 0 }, result)
    end)

    it(
      "dockerが実行できずvim_systemが例外を投げたとき終了コード127の結果に変換する",
      function()
        -- vim.system は実行ファイルが無いと終了コードではなく例外を投げる。
        -- 例外のまま伝播させると docker.Result の契約が崩れ、G11 の
        -- 「docker 未検出」を他の環境エラーと区別できなくなる。
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.system = function()
          error("ENOENT: no such file or directory")
        end

        local result = run_async({ "ps" })

        assert.is_false(result.ok)
        assert.are.equal(127, result.code)
        assert.is_truthy(
          tostring(result.error):find("executable not found", 1, true),
          "合成した stderr に executable not found が含まれること: " .. tostring(result.error)
        )
      end
    )

    it("作業ディレクトリが無くて起動できないときはdocker未検出と混同しない", function()
      -- cwd 不在も vim.system の例外として同じ経路に来る。docker 不在に丸めると
      -- 「docker をインストールしてください」と誤案内してしまう (compose は cwd を渡す)。
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.system = function()
        error("ENOENT: no such file or directory: cwd")
      end

      local result = run_async({ "compose", "ps" }, { cwd = "/no/such/dir" })

      assert.is_false(result.ok)
      assert.is_truthy(
        tostring(result.error):find("working directory not found", 1, true),
        "作業ディレクトリの問題だと分かる文言であること: " .. tostring(result.error)
      )
      assert.is_nil(tostring(result.error):find("executable not found", 1, true))
    end)

    it("dockerが実行できないとき接続確認は未検出のメッセージを返す", function()
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.system = function()
        error("ENOENT: no such file or directory")
      end

      local captured
      cli.check_connection(function(result)
        captured = result
      end)
      assert(
        vim.wait(3000, function()
          return captured ~= nil
        end),
        "on_done が呼ばれなかった"
      )

      assert.are.same({
        ok = false,
        data = nil,
        error = "docker コマンドが見つかりません。docker をインストールし PATH を通してください。",
        code = 127,
      }, captured)
    end)
  end)

  describe("check_connection", function()
    ---@return docker.Result
    local function check_sync()
      local captured
      cli.check_connection(function(result)
        captured = result
      end)
      return assert(captured, "on_done was not called")
    end

    it("接続できるとき成否が真でサーバのバージョンがdataに入る", function()
      stub_executor({ code = 0, stdout = "29.4.0\n" })

      assert.are.same({ ok = true, data = "29.4.0", error = nil, code = 0 }, check_sync())
    end)

    it("サーバのバージョンだけを取得する引数でdockerを呼ぶ", function()
      stub_executor({ code = 0, stdout = "29.4.0\n" })

      check_sync()

      assert.are.same({ "docker", "version", "--format", "{{.Server.Version}}" }, calls[1].cmd)
    end)

    it("SSH越しの鍵エラーをソケットの権限不足と取り違えない", function()
      -- `permission denied` だけで判定すると、docker context が SSH のときに出る
      -- 公開鍵エラーを「docker グループに属しているか確認してください」と誤案内する。
      stub_executor({ code = 1, stderr = "ssh: Permission denied (publickey)." })

      assert.are.same({
        ok = false,
        data = nil,
        error = "ssh: Permission denied (publickey).",
        code = 1,
      }, check_sync())
    end)

    it(
      "デーモンソケットの権限不足はソケットの文脈込みで権限エラーと判定する",
      function()
        stub_executor({
          code = 1,
          stderr = "Got permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock",
        })

        assert.are.same({
          ok = false,
          data = nil,
          error = "docker ソケットへのアクセス権限がありません。ユーザーが docker グループに属しているか確認してください。",
          code = 1,
        }, check_sync())
      end
    )

    it("dockerコマンドが見つからないとき導入を促すメッセージを返す", function()
      stub_executor({ code = 127, stderr = "docker: executable not found" })

      assert.are.same({
        ok = false,
        data = nil,
        error = "docker コマンドが見つかりません。docker をインストールし PATH を通してください。",
        code = 127,
      }, check_sync())
    end)

    it("デーモンに接続できないとき起動を促すメッセージを返す", function()
      stub_executor({
        code = 1,
        stderr = "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?",
      })

      assert.are.same({
        ok = false,
        data = nil,
        error = "docker デーモンに接続できません。docker が起動しているか確認してください。",
        code = 1,
      }, check_sync())
    end)

    it("docker29の文言でもデーモン未起動と権限不足をそれぞれ判定できる", function()
      -- docker 28 以前と 29 で文言が変わる。実機 (docker 29.4.0) から採取した文字列を
      -- 固定し、新しい docker で判定が黙って効かなくなる退行を検出する。
      local cases = {
        {
          stderr = "failed to connect to the docker API at unix:///var/run/docker.sock; check if the path is correct and if the daemon is running: dial unix /var/run/docker.sock: connect: no such file or directory",
          expected = "docker デーモンに接続できません。docker が起動しているか確認してください。",
        },
        {
          -- ソケットのパスが docker.sock でない構成 (colima / rancher / 独自 socket) でも
          -- 「docker API」への言及で権限エラーと判定できること。
          stderr = "permission denied while trying to connect to the docker API at unix:///var/run/engine.sock",
          expected = "docker ソケットへのアクセス権限がありません。ユーザーが docker グループに属しているか確認してください。",
        },
      }

      local actual = {}
      for _, case in ipairs(cases) do
        stub_executor({ code = 1, stderr = case.stderr })
        table.insert(actual, check_sync().error)
      end

      assert.are.same({ cases[1].expected, cases[2].expected }, actual)
    end)

    it("ソケットの権限が無いとき権限を示すメッセージを返す", function()
      stub_executor({
        code = 1,
        stderr = "dial unix /var/run/docker.sock: connect: permission denied",
      })

      assert.are.same({
        ok = false,
        data = nil,
        error = "docker ソケットへのアクセス権限がありません。ユーザーが docker グループに属しているか確認してください。",
        code = 1,
      }, check_sync())
    end)

    it("3つの環境エラーがそれぞれ区別できるメッセージになる", function()
      local messages = {}
      for _, stderr in ipairs({
        "docker: executable not found",
        "Cannot connect to the Docker daemon at unix:///var/run/docker.sock.",
        "dial unix /var/run/docker.sock: connect: permission denied",
      }) do
        stub_executor({ code = 1, stderr = stderr })
        local result = check_sync()
        table.insert(messages, result.error)
      end

      assert.are.same({
        "docker コマンドが見つかりません。docker をインストールし PATH を通してください。",
        "docker デーモンに接続できません。docker が起動しているか確認してください。",
        "docker ソケットへのアクセス権限がありません。ユーザーが docker グループに属しているか確認してください。",
      }, messages)
    end)

    it("いずれにも当てはまらない失敗はdockerの標準エラー出力をそのまま返す", function()
      stub_executor({ code = 1, stderr = "something else went wrong" })

      assert.are.same({
        ok = false,
        data = nil,
        error = "something else went wrong",
        code = 1,
      }, check_sync())
    end)
  end)

  describe("デバッグログ", function()
    local original_notify
    local notified

    before_each(function()
      notified = {}
      original_notify = vim.notify
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.notify = function(msg, level, opts)
        table.insert(notified, { msg = msg, level = level, opts = opts })
      end
    end)

    after_each(function()
      vim.notify = original_notify
    end)

    it("既定では実行したコマンドを通知しない", function()
      stub_executor({ code = 0, stdout = "" })

      run_sync({ "ps", "-a" })

      assert.are.same({}, notified)
    end)

    it("デバッグを有効にすると実行したコマンドと終了コードを通知する", function()
      notify.set_debug(true)
      stub_executor({ code = 0, stdout = "" })

      run_sync({ "ps", "-a" })

      assert.are.same({
        { msg = "docker ps -a (exit 0)", level = vim.log.levels.DEBUG, opts = { title = "docker.nvim" } },
      }, notified)
    end)

    it("デバッグを有効にすると解析に失敗した行数も通知する", function()
      notify.set_debug(true)
      stub_executor({ code = 0, stdout = '{"id":"a"}\nbroken\n' })

      run_sync({ "ps" }, { parse = "ndjson" })

      assert.are.same({
        { msg = "docker ps (exit 0)", level = vim.log.levels.DEBUG, opts = { title = "docker.nvim" } },
        { msg = "skipped 1 unparsable line(s)", level = vim.log.levels.DEBUG, opts = { title = "docker.nvim" } },
      }, notified)
    end)
  end)
end)
