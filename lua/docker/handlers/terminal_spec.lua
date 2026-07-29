local jobs = require("docker.handlers.jobs")
local terminal = require("docker.handlers.terminal")

describe("docker.handlers.terminal", function()
  local opened

  before_each(function()
    jobs._reset()
    jobs._set_stopper(function() end)
    opened = {}
    -- ターミナル生成を差し替える。実際に docker を起動せずに引数だけ検証する。
    -- 本番と同じく 1 ターミナルにつき 1 バッファを作る。
    terminal._set_opener(function(cmd, _)
      table.insert(opened, cmd)
      -- 本番のターミナルバッファと同様、切り替えても破棄されないバッファにする。
      local bufnr = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_set_current_buf(bufnr)
      return 100 + #opened
    end)
  end)

  after_each(function()
    terminal._set_opener(nil)
    jobs._reset()
  end)

  describe("発行する docker 引数", function()
    it("ログ追従はfオプション付きのdocker logsになる", function()
      terminal.open_logs("abc123", "web")

      assert.are.same({ "docker", "logs", "-f", "abc123" }, opened[1])
    end)

    it("シェル起動はbashがあればbashを使いなければshにする", function()
      -- BR-019: コンテナ内に bash があるとは限らない。
      terminal.open_shell("abc123", "web")

      local cmd = opened[1]
      assert.are.same({ "docker", "exec", "-it", "abc123", "sh", "-c" }, { unpack(cmd, 1, 6) })
      local snippet = cmd[7]
      assert.is_truthy(snippet:find("bash", 1, true), "bash を試すこと: " .. snippet)
      assert.is_truthy(snippet:find("sh", 1, true), "sh に落ちること: " .. snippet)
    end)

    it("コマンド実行は指定したコマンドをそのまま渡す", function()
      terminal.open_exec("abc123", "web", "ls -la /etc")

      assert.are.same({ "docker", "exec", "-it", "abc123", "ls", "-la", "/etc" }, opened[1])
    end)

    it("空白を含むコマンドは語ごとに分けて渡す", function()
      terminal.open_exec("abc123", "web", "  env   -i  ")

      assert.are.same({ "docker", "exec", "-it", "abc123", "env", "-i" }, opened[1])
    end)
  end)

  describe("ジョブ台帳", function()
    it("起動したターミナルのジョブを台帳に載せる", function()
      terminal.open_logs("abc123", "web")

      assert.are.same({ 101 }, jobs.list())
    end)

    it("複数のターミナルを開くとそれぞれ台帳に載る", function()
      terminal.open_logs("abc123", "web")
      terminal.open_shell("def456", "db")

      assert.are.same({ 101, 102 }, jobs.list())
    end)

    it("バッファが破棄されるとジョブ台帳から消える", function()
      -- G4: ターミナルを閉じたら子プロセスを追跡対象から外す。
      local handle = terminal.open_logs("abc123", "web")

      terminal._on_buffer_closed(handle.bufnr)

      assert.are.same({}, jobs.list())
    end)

    it("バッファ破棄で消えるのは対応するジョブだけになる", function()
      local first = terminal.open_logs("abc123", "web")
      terminal.open_shell("def456", "db")

      terminal._on_buffer_closed(first.bufnr)

      assert.are.same({ 102 }, jobs.list())
    end)
  end)

  describe("戻り値", function()
    it("バッファ番号とジョブIDを返す", function()
      local handle = terminal.open_logs("abc123", "web")

      assert.are.equal(101, handle.job_id)
      assert.is_true(type(handle.bufnr) == "number")
    end)
  end)
end)
