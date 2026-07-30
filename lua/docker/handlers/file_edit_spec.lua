local cli = require("docker.adapters.docker.cli")
local file_edit = require("docker.handlers.file_edit")
local window = require("docker.ui.window")

describe("docker.handlers.file_edit", function()
  local runs, notified
  local original_notify
  local opened_buffers

  --- `docker cp` を横取りし、取り出し側では中身を書き出す偽の docker。
  ---@param opts { fail_pull: boolean|nil, fail_push: boolean|nil, contents: string[]|nil }
  local function stub(opts)
    cli._set_executor(function(cmd, _, on_exit)
      table.insert(runs, cmd)
      local source, destination = cmd[3], cmd[4]
      local pulling = source:find(":", 1, true) ~= nil
      if pulling then
        if opts.fail_pull then
          on_exit({ code = 1, stdout = "", stderr = "Error: No such container:path" })
          return
        end
        vim.fn.writefile(opts.contents or { "hello" }, destination)
        on_exit({ code = 0, stdout = "", stderr = "" })
        return
      end
      if opts.fail_push then
        on_exit({ code = 1, stdout = "", stderr = "Error: permission denied" })
        return
      end
      on_exit({ code = 0, stdout = "", stderr = "" })
    end)
  end

  ---@return integer|nil
  local function open(id, label, path)
    local captured, called = nil, false
    file_edit.open(id, label, path, function(bufnr)
      captured, called = bufnr, true
    end)
    assert(vim.wait(3000, function()
      return called
    end))
    if captured then
      table.insert(opened_buffers, captured)
    end
    return captured
  end

  before_each(function()
    runs, notified, opened_buffers = {}, {}, {}
    file_edit._reset()
    original_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end
  end)

  after_each(function()
    for _, bufnr in ipairs(opened_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    -- 開いたウィンドウを片付ける。溜めたままだと分割が積み上がって
    -- 途中から E36 (Not enough room) で開けなくなる。
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if #vim.api.nvim_tabpage_list_wins(0) > 1 then
        pcall(vim.api.nvim_win_close, winid, true)
      end
    end
    vim.notify = original_notify
    cli._set_executor(nil)
    file_edit._reset()
  end)

  describe("open", function()
    it("コンテナからファイルを取り出す", function()
      stub({})

      open("abc123", "web", "/etc/hosts")

      assert.are.equal("docker", runs[1][1])
      assert.are.equal("cp", runs[1][2])
      assert.are.equal("abc123:/etc/hosts", runs[1][3])
    end)

    it("バッファ名をdockerスキームにする", function()
      stub({})

      local bufnr = assert(open("abc123", "web", "/etc/hosts"))

      assert.are.equal("docker://web/etc/hosts", vim.fn.bufname(bufnr))
    end)

    it("取り出した内容をバッファに読み込む", function()
      stub({ contents = { "line1", "line2" } })

      local bufnr = assert(open("abc123", "web", "/etc/hosts"))

      assert.are.same({ "line1", "line2" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      assert.is_false(vim.bo[bufnr].modified, "開いた直後は未変更であること")
    end)

    it("一時ファイルの名前にコンテナごとの識別子が入る", function()
      -- 名前がパスだけだと、別のコンテナの同じパスで内容を取り違える。
      local pulled = {}
      cli._set_executor(function(cmd, _, on_exit)
        table.insert(pulled, cmd[4])
        vim.fn.writefile({ "x" }, cmd[4])
        on_exit({ code = 0, stdout = "", stderr = "" })
      end)

      open("aaaaaaaaaaaa", "web", "/etc/hosts")
      open("bbbbbbbbbbbb", "db", "/etc/hosts")

      assert.are.equal(2, #pulled)
      assert.is_true(pulled[1] ~= pulled[2], "一時ファイルの名前が別になること: " .. pulled[1])
    end)

    it("同じパスを別のコンテナで開いても書き戻し先が混ざらない", function()
      stub({})
      local first = assert(open("aaaaaaaaaaaa", "web", "/etc/hosts"))
      local second = assert(open("bbbbbbbbbbbb", "db", "/etc/hosts"))

      assert.is_true(first ~= second, "別のバッファになること")

      runs = {}
      vim.api.nvim_buf_set_lines(second, 0, -1, false, { "changed" })
      file_edit.write(second)
      assert(vim.wait(2000, function()
        return #runs > 0
      end))

      assert.are.equal("bbbbbbbbbbbb:/etc/hosts", runs[1][4], "2 つ目のコンテナへ書き戻すこと")
    end)

    it("名前が前方一致する別のバッファを掴まない", function()
      -- 名前でバッファを探すときにパターン照合を使うと、利用者が開いていた
      -- docker://web/etc/hosts.orig を「同じファイル」と誤認して
      -- コンテナの中身で上書きしてしまう。
      stub({ contents = { "コンテナの内容" } })
      local other = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(other, "docker://web/etc/hosts.orig")
      vim.api.nvim_buf_set_lines(other, 0, -1, false, { "利用者の内容" })

      local bufnr = assert(open("abc123", "web", "/etc/hosts"))

      assert.is_true(bufnr ~= other, "別のバッファを使うこと")
      assert.are.same({ "利用者の内容" }, vim.api.nvim_buf_get_lines(other, 0, -1, false))
      vim.api.nvim_buf_delete(other, { force = true })
    end)

    it("ディレクトリを指定したときは開かずに取り出した中身も残さない", function()
      -- `docker cp` はディレクトリを指定すると丸ごと降ろす。そのまま
      -- readfile に渡すと例外になり、降ろした中身がキャッシュに残り続ける。
      local pulled
      cli._set_executor(function(cmd, _, on_exit)
        table.insert(runs, cmd)
        pulled = cmd[4]
        vim.fn.mkdir(pulled .. "/sub", "p")
        vim.fn.writefile({ "x" }, pulled .. "/sub/file")
        on_exit({ code = 0, stdout = "", stderr = "" })
      end)

      local bufnr = open("abc123", "web", "/etc")

      assert.is_nil(bufnr, "バッファを開かないこと")
      assert.are.same(
        { msg = "/etc はディレクトリなので編集できません", level = vim.log.levels.ERROR },
        notified[#notified]
      )
      assert.are.equal(
        0,
        vim.fn.isdirectory(pulled),
        "取り出した中身を残さないこと: " .. tostring(pulled)
      )
    end)

    it("取り出しに失敗するとバッファを開かない", function()
      stub({ fail_pull = true })

      local bufnr = open("abc123", "web", "/nope")

      assert.is_nil(bufnr)
      assert.are.equal(vim.log.levels.ERROR, notified[#notified].level)
    end)

    it("フォーカスのあるフロートのバッファを奪わない", function()
      -- フロートにフォーカスがある状態でバッファを差し替えると、bufhidden=wipe の
      -- 一覧バッファが破棄され、フロートだけが生き残って一覧が二度と描画されない。
      stub({})
      local float = window.open({ title = "Containers" })
      window.set_lines(float, { "web  alpine" })

      open("abc123", "web", "/etc/hosts")

      assert.is_true(vim.api.nvim_buf_is_valid(float.bufnr), "一覧のバッファが生きていること")
      assert.are.same({ "web  alpine" }, vim.api.nvim_buf_get_lines(float.bufnr, 0, -1, false))
      window.close(float)
    end)

    it("フロートとは別のウィンドウに開く", function()
      stub({})
      local float = window.open({ title = "Containers" })

      local bufnr = assert(open("abc123", "web", "/etc/hosts"))

      local winid = vim.api.nvim_get_current_win()
      assert.is_true(winid ~= float.winid, "フロートとは別のウィンドウであること")
      assert.are.equal(bufnr, vim.api.nvim_win_get_buf(winid), "開いたバッファが出ていること")
      window.close(float)
    end)

    it("既に開いているファイルは同じウィンドウへ戻る", function()
      -- 開くたびに分割を足すと、同じファイルの窓が何枚も積み上がる。
      stub({})
      local bufnr = assert(open("abc123", "web", "/etc/hosts"))
      local first_win = vim.api.nvim_get_current_win()
      local windows_before = #vim.api.nvim_tabpage_list_wins(0)

      assert.are.equal(bufnr, open("abc123", "web", "/etc/hosts"))

      assert.are.equal(first_win, vim.api.nvim_get_current_win(), "同じウィンドウへ戻ること")
      assert.are.equal(windows_before, #vim.api.nvim_tabpage_list_wins(0), "窓が増えないこと")
    end)

    it("保存を横取りするバッファ種別にする", function()
      stub({})

      local bufnr = assert(open("abc123", "web", "/etc/hosts"))

      assert.are.equal("acwrite", vim.bo[bufnr].buftype)
    end)
  end)

  describe("バッファの後始末", function()
    it("同じファイルを2回開いても書き戻しは1回だけ走る", function()
      -- 開くたびに BufWriteCmd を重ねて張ると、保存 1 回で docker cp が
      -- 何度も走り、通知も回数ぶん出る。
      stub({})
      local bufnr = assert(open("abc123", "web", "/etc/hosts"))
      assert.are.equal(bufnr, open("abc123", "web", "/etc/hosts"), "同じバッファを使い回すこと")
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "changed" })
      runs = {}

      vim.cmd("silent write")
      vim.wait(1000, function()
        return #runs > 1
      end)

      assert.are.equal(1, #runs, "書き戻しは 1 回だけ")
    end)

    it("バッファを閉じると書き戻し先の対応付けが外れる", function()
      -- `:bdelete` はバッファ番号を残したまま解放するため、番号だけを
      -- 見ていると閉じた後も書き戻せてしまう。
      stub({})
      local bufnr = assert(open("abc123", "web", "/etc/hosts"))
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "changed" })
      runs = {}

      file_edit.write(bufnr)
      assert(vim.wait(2000, function()
        return #runs > 0
      end))
      assert.are.equal("abc123:/etc/hosts", runs[1][4], "閉じる前は書き戻せること")

      vim.cmd(("silent %dbdelete!"):format(bufnr))
      runs = {}
      file_edit.write(bufnr)
      vim.wait(500, function()
        return #runs > 0
      end)

      assert.are.same({}, runs, "閉じた後は書き戻さないこと")
    end)

    it("閉じたバッファを開き直しても書き戻しは1回だけ走る", function()
      -- `:bdelete` ではバッファ番号が生き残るため、開き直しで同じ番号を
      -- 掴む。後始末で横取りを解いておかないと BufWriteCmd が二重に張られる。
      stub({})
      local first = assert(open("abc123", "web", "/etc/hosts"))
      vim.cmd(("silent %dbdelete!"):format(first))

      local second = assert(open("abc123", "web", "/etc/hosts"))
      vim.api.nvim_buf_set_lines(second, 0, -1, false, { "changed" })
      runs = {}

      vim.cmd("silent write")
      vim.wait(1000, function()
        return #runs > 1
      end)

      assert.are.equal(1, #runs, "書き戻しは 1 回だけ")
    end)

    it("バッファを破棄すると一時ファイルも消える", function()
      -- 取り出した中身がキャッシュへ残り続けると、コンテナの中身が
      -- ホスト側に溜まる。
      local pulled
      cli._set_executor(function(cmd, _, on_exit)
        table.insert(runs, cmd)
        pulled = cmd[4]
        vim.fn.writefile({ "hello" }, pulled)
        on_exit({ code = 0, stdout = "", stderr = "" })
      end)
      local bufnr = assert(open("abc123", "web", "/etc/hosts"))
      assert.are.equal(1, vim.fn.filereadable(pulled), "取り出した時点では在ること")

      vim.api.nvim_buf_delete(bufnr, { force = true })

      assert.are.equal(0, vim.fn.filereadable(pulled), "破棄したら消えること: " .. tostring(pulled))
    end)
  end)

  describe("保存", function()
    it("書き込むとコンテナへ書き戻す", function()
      stub({})
      local bufnr = assert(open("abc123", "web", "/etc/hosts"))
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "changed" })
      runs = {}

      file_edit.write(bufnr)
      assert(vim.wait(2000, function()
        return #runs > 0
      end))

      assert.are.equal("abc123:/etc/hosts", runs[1][4])
    end)

    it("書き戻しに成功すると未変更になる", function()
      stub({})
      local bufnr = assert(open("abc123", "web", "/etc/hosts"))
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "changed" })
      assert.is_true(vim.bo[bufnr].modified)

      file_edit.write(bufnr)
      assert(vim.wait(2000, function()
        return not vim.bo[bufnr].modified
      end))

      assert.is_false(vim.bo[bufnr].modified)
    end)

    it("書き戻しに失敗すると変更を保持したままにする", function()
      -- modified を落とすと、書き戻せていないのに保存済みに見えてしまう。
      stub({ fail_push = true })
      local bufnr = assert(open("abc123", "web", "/etc/hosts"))
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "changed" })

      file_edit.write(bufnr)
      assert(vim.wait(2000, function()
        return #notified > 0 and notified[#notified].level == vim.log.levels.ERROR
      end))

      assert.is_true(vim.bo[bufnr].modified, "変更が残ること")
    end)

    it("書き込みコマンドで書き戻しが走る", function()
      -- BufWriteCmd の横取りが実際に効いているかを :write で確かめる。
      -- open が開いたウィンドウにフォーカスがあるので、そのまま :write できる。
      stub({})
      local bufnr = assert(open("abc123", "web", "/etc/hosts"))
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "changed" })
      runs = {}

      vim.cmd("silent write")
      assert(vim.wait(2000, function()
        return #runs > 0
      end))

      assert.are.equal("abc123:/etc/hosts", runs[1][4])
    end)
  end)
end)
