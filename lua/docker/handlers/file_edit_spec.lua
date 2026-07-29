local cli = require("docker.adapters.docker.cli")
local file_edit = require("docker.handlers.file_edit")

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

    it("取り出しに失敗するとバッファを開かない", function()
      stub({ fail_pull = true })

      local bufnr = open("abc123", "web", "/nope")

      assert.is_nil(bufnr)
      assert.are.equal(vim.log.levels.ERROR, notified[#notified].level)
    end)

    it("保存を横取りするバッファ種別にする", function()
      stub({})

      local bufnr = assert(open("abc123", "web", "/etc/hosts"))

      assert.are.equal("acwrite", vim.bo[bufnr].buftype)
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
      stub({})
      local bufnr = assert(open("abc123", "web", "/etc/hosts"))
      vim.api.nvim_win_set_buf(0, bufnr)
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
