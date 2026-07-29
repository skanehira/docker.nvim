local jobs = require("docker.handlers.jobs")
local terminal = require("docker.handlers.terminal")
local window = require("docker.ui.window")

describe("docker.handlers.terminal", function()
  local started
  local next_job_id

  before_each(function()
    jobs._reset()
    jobs._set_stopper(function() end)
    started = {}
    next_job_id = 100
    -- 差し替えるのはジョブ起動だけ。ウィンドウとバッファの用意は本番経路を通す
    -- (ここを丸ごと差し替えると、実際に一覧を壊す不具合がテストに掛からない)。
    terminal._set_job_starter(function(cmd)
      table.insert(started, cmd)
      next_job_id = next_job_id + 1
      return next_job_id
    end)
  end)

  after_each(function()
    terminal._set_job_starter(nil)
    jobs._reset()
    -- テストで開いたターミナル用のウィンドウを片付ける
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if #vim.api.nvim_tabpage_list_wins(0) > 1 then
        pcall(vim.api.nvim_win_close, winid, true)
      end
    end
  end)

  describe("発行する docker 引数", function()
    it("ログ追従はfオプション付きのdocker logsになる", function()
      terminal.open_logs("abc123", "web")

      assert.are.same({ "docker", "logs", "-f", "abc123" }, started[1])
    end)

    it("シェル起動はbashがあればbashを使いなければshにする", function()
      -- BR-019: コンテナ内に bash があるとは限らない。
      terminal.open_shell("abc123", "web")

      local cmd = started[1]
      assert.are.same({ "docker", "exec", "-it", "abc123", "sh", "-c" }, { unpack(cmd, 1, 6) })
      local snippet = cmd[7]
      assert.is_truthy(snippet:find("exec bash", 1, true), "bash を試すこと: " .. snippet)
      assert.is_truthy(snippet:find("exec sh", 1, true), "bash が無ければ sh に落ちること: " .. snippet)
    end)

    it("コマンド実行は指定したコマンドをそのまま渡す", function()
      terminal.open_exec("abc123", "web", "ls -la /etc")

      assert.are.same({ "docker", "exec", "-it", "abc123", "ls", "-la", "/etc" }, started[1])
    end)

    it("引用符で囲んだ引数は1語として渡す", function()
      -- `sh -c 'echo hello world'` が 3 語に割れると意図と違うコマンドになる。
      terminal.open_exec("abc123", "web", "sh -c 'echo hello world'")

      assert.are.same({ "docker", "exec", "-it", "abc123", "sh", "-c", "echo hello world" }, started[1])
    end)

    it("前後の空白は取り除く", function()
      terminal.open_exec("abc123", "web", "  env   -i  ")

      assert.are.same({ "docker", "exec", "-it", "abc123", "env", "-i" }, started[1])
    end)
  end)

  describe("ウィンドウの扱い", function()
    it("一覧のフロートを開いたまま起動しても一覧のバッファを奪わない", function()
      -- フロートにフォーカスがある状態で `enew` すると、bufhidden=wipe の
      -- 一覧バッファが破棄され、一覧が二度と開けなくなる。
      local float = window.open({ title = "Containers" })
      window.set_lines(float, { "web  alpine" })

      terminal.open_logs("abc123", "web")

      assert.is_true(vim.api.nvim_buf_is_valid(float.bufnr), "一覧のバッファが生きていること")
      assert.are.same({ "web  alpine" }, vim.api.nvim_buf_get_lines(float.bufnr, 0, -1, false))
      window.close(float)
    end)

    it("一覧のフロートとは別のウィンドウに開く", function()
      local float = window.open({ title = "Containers" })

      local handle = terminal.open_logs("abc123", "web")

      assert.is_true(handle.bufnr ~= float.bufnr)
      window.close(float)
    end)
  end)

  describe("ジョブ台帳", function()
    it("起動したターミナルのジョブを台帳に載せる", function()
      terminal.open_logs("abc123", "web")

      assert.are.same({ 101 }, jobs.list())
    end)

    it("同じコンテナで2つ目のターミナルを開いても両方が台帳に載る", function()
      -- バッファ名が衝突すると E95 で例外になり、起動済みのジョブが
      -- 台帳から漏れる (:qa の後に子プロセスが残る)。
      terminal.open_logs("abc123", "web")
      terminal.open_logs("abc123", "web")

      assert.are.same({ 101, 102 }, jobs.list())
    end)

    it("バッファを破棄すると台帳から消える", function()
      -- G4: テスト専用の入口ではなく、実際の autocmd を通して確認する。
      local handle = terminal.open_logs("abc123", "web")

      vim.api.nvim_buf_delete(handle.bufnr, { force = true })

      assert.are.same({}, jobs.list())
    end)

    it("バッファ破棄で消えるのは対応するジョブだけになる", function()
      local first = terminal.open_logs("abc123", "web")
      terminal.open_shell("def456", "db")

      vim.api.nvim_buf_delete(first.bufnr, { force = true })

      assert.are.same({ 102 }, jobs.list())
    end)

    it("ジョブの起動に失敗したら台帳に載せない", function()
      terminal._set_job_starter(function()
        return 0
      end)

      terminal.open_logs("abc123", "web")

      assert.are.same({}, jobs.list())
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
