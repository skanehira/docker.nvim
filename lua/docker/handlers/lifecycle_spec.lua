local cli = require("docker.adapters.docker.cli")
local config = require("docker.config")
local lifecycle = require("docker.handlers.lifecycle")
local operations = require("docker.handlers.operations")
local store = require("docker.state.store")

describe("docker.handlers.lifecycle", function()
  local notified
  local original_notify

  before_each(function()
    notified = {}
    config._reset()
    store._reset()
    operations._reset()
    lifecycle.close_all()
    original_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end
    -- 接続確認と一覧取得の両方に応える偽の docker。
    cli._set_executor(function(cmd, _, on_exit)
      if cmd[2] == "version" then
        on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
      else
        on_exit({
          code = 0,
          stderr = "",
          stdout = '{"id":"abc123","name":"web","image":"alpine","state":"running","status":"Up 5 days",'
            .. '"ports":"","command":"sleep","created_at":"now","compose_project":"",'
            .. '"compose_service":"","compose_oneoff":""}\n',
        })
      end
    end)
  end)

  --- ビューが開き終わるまで待つ (docker への接続確認が非同期のため)。
  ---@param kind string
  ---@return docker.ViewHandle|nil
  local function open_view(kind)
    local captured, called = nil, false
    lifecycle.open(kind, function(handle)
      captured, called = handle, true
    end)
    assert(
      vim.wait(3000, function()
        return called
      end),
      "open のコールバックが呼ばれなかった"
    )
    return captured
  end

  after_each(function()
    lifecycle.close_all()
    vim.notify = original_notify
    cli._set_executor(nil)
    config._reset()
    store._reset()
  end)

  describe("open", function()
    it("一覧ビューを開く", function()
      local handle = assert(open_view("container"))
      assert.is_true(vim.api.nvim_win_is_valid(handle.window.winid))
    end)

    it("取得した内容をバッファへ描画する", function()
      local handle = assert(open_view("container"))

      local lines = vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false)
      assert.is_truthy(lines[1]:find("web", 1, true), lines[1])
    end)

    it("同じ種別を再度開くと新しいバッファを作らず既存へ移動する", function()
      -- US-026: 複数タブで開いてもバッファは 1 つに保つ。
      local first = assert(open_view("container"))

      local second = assert(open_view("container"))

      assert.are.equal(first.window.bufnr, second.window.bufnr)
    end)

    it("キーマップをバッファローカルに設定する", function()
      -- BR-014: 一覧ビュー以外のバッファでプラグインのキーが作用しない。
      local handle = assert(open_view("container"))

      local mapped = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(handle.window.bufnr, "n")) do
        mapped[m.lhs] = true
      end
      assert.is_true(mapped["u"], "start のキーが設定されていること")
      assert.is_true(mapped["q"], "close のキーが設定されていること")
    end)

    it("プラグインのキーは他のバッファには設定されない", function()
      open_view("container")

      local scratch = vim.api.nvim_create_buf(false, true)
      assert.are.same({}, vim.api.nvim_buf_get_keymap(scratch, "n"))
      vim.api.nvim_buf_delete(scratch, { force = true })
    end)

    it("未知の種別は開かずに警告する", function()
      local handle = open_view("nonexistent")

      assert.is_nil(handle)
      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
    end)

    it("dockerに接続できないときはビューを開かずエラーを通知する", function()
      cli._set_executor(function(_, _, on_exit)
        on_exit({ code = 1, stdout = "", stderr = "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" })
      end)

      local handle = open_view("container")

      assert.is_nil(handle)
      local last = notified[#notified]
      assert.are.equal(vim.log.levels.ERROR, last.level)
      assert.is_truthy(last.msg:find("デーモン", 1, true), last.msg)
    end)
  end)

  describe("close", function()
    it("ビューを閉じる", function()
      local handle = assert(open_view("container"))

      lifecycle.close("container")

      assert.is_false(vim.api.nvim_win_is_valid(handle.window.winid))
    end)

    it("閉じた後に開くと新しいバッファになる", function()
      local first = assert(open_view("container"))
      lifecycle.close("container")

      local second = assert(open_view("container"))

      assert.is_true(first.window.bufnr ~= second.window.bufnr)
    end)

    it("開いていない種別を閉じてもエラーにならない", function()
      lifecycle.close("container")
    end)
  end)

  describe("close_all", function()
    it("開いている全てのビューを閉じる", function()
      local handle = assert(open_view("container"))

      lifecycle.close_all()

      assert.is_false(vim.api.nvim_win_is_valid(handle.window.winid))
    end)
  end)

  describe("キー操作のディスパッチ", function()
    ---@param handle table
    ---@param key string
    local function press(handle, key)
      vim.api.nvim_set_current_win(handle.window.winid)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
    end

    it("qで一覧が閉じる", function()
      local handle = assert(open_view("container"))

      press(handle, "q")

      assert.is_nil(lifecycle.get("container"))
    end)

    it("?でヘルプが前面に開く", function()
      local handle = assert(open_view("container"))

      press(handle, "?")

      local current = vim.api.nvim_get_current_win()
      assert.is_true(current ~= handle.window.winid, "ヘルプのウィンドウへ移ること")
      local joined = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      assert.is_truthy(joined:find("start", 1, true), joined)
    end)

    it("Rで一覧を取り直すためdockerを再度呼ぶ", function()
      -- 行数だけを見ていると、R が何もしなくても気付けない。
      local handle = assert(open_view("container"))
      local calls = {}
      cli._set_executor(function(cmd, _, on_exit)
        table.insert(calls, cmd)
        on_exit({ code = 0, stdout = "", stderr = "" })
      end)

      press(handle, "R")

      assert.are.equal(1, #calls, "一覧取得を 1 回発行すること")
      assert.are.equal("ps", calls[1][2])
    end)
  end)

  describe("非同期な接続確認との競合", function()
    it("応答を待っている間に再度開いてもフロートが二重に開かない", function()
      -- `:Docker containers` を連打すると、接続確認の応答前に何枚も開いてしまう。
      -- 孤児になったフロートは q でも close() でも閉じられなくなる。
      local pending_replies = {}
      cli._set_executor(function(cmd, _, on_exit)
        -- 接続確認の応答を保留し、その間に 2 回目・3 回目を発行する
        table.insert(pending_replies, function()
          if cmd[2] == "version" then
            on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
          else
            on_exit({ code = 0, stdout = "", stderr = "" })
          end
        end)
      end)

      local before = #vim.api.nvim_list_wins()
      lifecycle.open("container")
      lifecycle.open("container")
      lifecycle.open("container")
      for _, reply in ipairs(pending_replies) do
        reply()
      end
      vim.wait(200)

      local opened = #vim.api.nvim_list_wins() - before
      assert.is_true(opened <= 1, ("開いたウィンドウは 1 枚まで (実際 %d 枚)"):format(opened))
    end)

    it("接続に失敗した後でも改めて開ける", function()
      cli._set_executor(function(_, _, on_exit)
        on_exit({ code = 1, stdout = "", stderr = "Cannot connect to the Docker daemon" })
      end)
      assert.is_nil(open_view("container"))

      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "version" then
          on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
        else
          on_exit({ code = 0, stdout = "", stderr = "" })
        end
      end)

      assert.is_truthy(open_view("container"), "失敗後に開けなくならないこと")
    end)
  end)

  describe("実行中表示の結線", function()
    it("操作を開始すると一覧に実行中の印が出る", function()
      -- 台帳に印を付けるだけでは画面は変わらない。再描画まで繋がっている必要がある。
      local handle = assert(open_view("container"))
      assert.is_nil(vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, 1, false)[1]:find("実行中", 1, true))

      operations.begin("abc123", "stop")

      assert.is_truthy(
        vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, 1, false)[1]:find("実行中", 1, true),
        vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, 1, false)[1]
      )
    end)

    it("操作が終わると実行中の印が消える", function()
      local handle = assert(open_view("container"))
      operations.begin("abc123", "stop")

      operations.finish("abc123", "stop")

      assert.is_nil(vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, 1, false)[1]:find("実行中", 1, true))
    end)
  end)

  describe("再描画とカーソル", function()
    it("再取得してもカーソル行が先頭へ戻らない", function()
      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "version" then
          on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
        else
          local rows = {}
          for i = 1, 5 do
            table.insert(
              rows,
              ('{"id":"id%d","name":"c%d","image":"alpine","state":"running","status":"Up",'):format(i, i)
                .. '"ports":"","command":"x","created_at":"now","compose_project":"","compose_service":"","compose_oneoff":""}'
            )
          end
          on_exit({ code = 0, stdout = table.concat(rows, "\n") .. "\n", stderr = "" })
        end
      end)
      local handle = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 4, 0 })

      lifecycle.refresh_view("container")

      assert.are.equal(4, vim.api.nvim_win_get_cursor(handle.window.winid)[1])
    end)
  end)

  describe("キーマップの適用範囲", function()
    it("プラグインのキーをグローバルに張らない", function()
      -- BR-014: 一覧ビュー以外のバッファでプラグインのキーが作用しない。
      -- `nvim_buf_get_keymap` はバッファローカルしか見ないためグローバル併設を
      -- 検出できない。グローバルのマップ一覧に一覧ビューのキーが無いことを直接見る。
      -- (前のテストで既に開いている可能性があるので、差分ではなく実在で判定する)
      assert(open_view("container"))

      local global = {}
      for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
        global[m.lhs] = true
      end

      local leaked = {}
      for _, key in ipairs({ "u", "d", "r", "t", "a", "e", "E", "q", "R", "?" }) do
        if global[key] then
          table.insert(leaked, key)
        end
      end
      assert.are.same({}, leaked, "グローバルへ漏れたキー: " .. vim.inspect(leaked))
    end)

    it("ビューを閉じるとそのバッファのキーも消える", function()
      local handle = assert(open_view("container"))
      local bufnr = handle.window.bufnr

      lifecycle.close("container")

      assert.is_false(vim.api.nvim_buf_is_valid(bufnr), "バッファごと破棄されること")
    end)
  end)

  describe("ビュー切替", function()
    it("選んだ種別へ切り替えて元のビューを閉じる", function()
      local handle = assert(open_view("container"))
      local original_select = vim.ui.select
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.select = function(items, _, on_choice)
        -- images を選ぶ
        for _, item in ipairs(items) do
          if item == "images" then
            on_choice(item)
            return
          end
        end
        on_choice(nil)
      end

      lifecycle.dispatch_for_test(handle, "switch_view")
      vim.wait(1000, function()
        return lifecycle.get("image") ~= nil
      end)
      vim.ui.select = original_select

      assert.is_truthy(lifecycle.get("image"), "切替先が開くこと")
      assert.is_nil(lifecycle.get("container"), "元のビューは閉じること")
    end)

    it("選択をキャンセルすると今のビューが残る", function()
      local handle = assert(open_view("container"))
      local original_select = vim.ui.select
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.select = function(_, _, on_choice)
        on_choice(nil)
      end

      lifecycle.dispatch_for_test(handle, "switch_view")
      vim.wait(200)
      vim.ui.select = original_select

      assert.is_truthy(lifecycle.get("container"), "今のビューが残ること")
    end)

    it("切替先を開けなかったときは今のビューを閉じない", function()
      -- compose プロジェクト外で services へ切り替えた場合など。
      local handle = assert(open_view("container"))
      local original_select = vim.ui.select
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.select = function(_, _, on_choice)
        on_choice("services")
      end
      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "version" then
          on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
        else
          on_exit({ code = 1, stdout = "", stderr = "no configuration file provided: not found" })
        end
      end)

      lifecycle.dispatch_for_test(handle, "switch_view")
      vim.wait(500)
      vim.ui.select = original_select

      assert.is_nil(lifecycle.get("service"))
      assert.is_truthy(lifecycle.get("container"), "切替に失敗したら今のビューを残すこと")
    end)
  end)
end)
