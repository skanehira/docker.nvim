local cli = require("docker.adapters.docker.cli")
local config = require("docker.config")
local lifecycle = require("docker.handlers.lifecycle")
local operations = require("docker.handlers.operations")
local store = require("docker.state.store")

describe("docker.handlers.lifecycle", function()
  local notified
  local original_notify

  --- 接続確認と一覧取得の両方に応える偽の docker。
  local function fake_docker(cmd, _, on_exit)
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
  end

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
    cli._set_executor(fake_docker)
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

    it("開き終わる前に閉じられても同じ種別のフロートが2枚にならない", function()
      -- 応答待ちの間に close_all が走ると受付が戻るため、2 回目の応答で
      -- もう 1 枚開き、閉じられない孤児のフロートが残る。
      local replies = {}
      cli._set_executor(function(cmd, _, on_exit)
        table.insert(replies, function()
          if cmd[2] == "version" then
            on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
          else
            on_exit({ code = 0, stdout = "", stderr = "" })
          end
        end)
      end)

      local before = #vim.api.nvim_list_wins()
      lifecycle.open("container")
      lifecycle.close_all()
      lifecycle.open("container")
      for _, reply in ipairs(replies) do
        reply()
      end
      vim.wait(200)

      local opened = #vim.api.nvim_list_wins() - before
      assert.are.equal(1, opened, ("開いたままのフロートは 1 枚 (実際 %d 枚)"):format(opened))
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

  describe("一覧の桁揃え", function()
    --- 実際に画面へ出る見出し。
    ---@param handle docker.ViewHandle
    ---@return string
    local function rendered_winbar(handle)
      return vim.api.nvim_eval_statusline(vim.wo[handle.window.winid].winbar, {
        winid = handle.window.winid,
        maxwidth = vim.api.nvim_win_get_width(handle.window.winid),
        use_winbar = true,
      }).str
    end

    it("行が長くても画面行とデータ行の数が一致する", function()
      -- 折り返すと 1 行が画面 2 行になり、以降の行が下へずれて見出しと対応しなくなる。
      cli._set_executor(function(cmd, opts, on_exit)
        if cmd[2] == "ps" then
          on_exit({
            code = 0,
            stderr = "",
            stdout = vim.json.encode({
              id = "abc123",
              name = "web",
              image = "alpine",
              state = "running",
              status = "Up 5 days",
              ports = string.rep("0.0.0.0:5001->5000/tcp, ", 20),
              command = "sleep",
              created_at = "now",
              compose_project = "",
              compose_service = "",
              compose_oneoff = "",
            })
              .. "\n"
              .. '{"id":"def456","name":"db","image":"postgres","state":"running","status":"Up 1 day",'
              .. '"ports":"","command":"sleep","created_at":"now","compose_project":"",'
              .. '"compose_service":"","compose_oneoff":""}\n',
          })
          return
        end
        fake_docker(cmd, opts, on_exit)
      end)

      local handle = assert(open_view("container"))

      local buffer_lines = vim.api.nvim_buf_line_count(handle.window.bufnr)
      assert.are.equal(2, buffer_lines, "2 件が並ぶこと")
      assert.are.equal(buffer_lines, vim.api.nvim_win_text_height(handle.window.winid, {}).all)
    end)

    it("横スクロールすると見出しも一緒に動く", function()
      local handle = assert(open_view("container"))
      local before = rendered_winbar(handle)
      assert.are.equal("NAME", before:sub(1, 4), before)

      vim.api.nvim_win_call(handle.window.winid, function()
        vim.fn.winrestview({ leftcol = 6 })
      end)
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = handle.window.bufnr })

      local after = rendered_winbar(handle)
      assert.are.equal(before:sub(7, 10), after:sub(1, 4), ("before=%s after=%s"):format(before, after))
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

  describe("フォーカスが外れたとき", function()
    --- 通常のウィンドウ (ターミナルを開いたときと同じ形) を下に作って移る。
    ---@return integer
    local function enter_plain_window()
      vim.cmd("botright new")
      return vim.api.nvim_get_current_win()
    end

    after_each(function()
      -- テストで作った通常ウィンドウを片付ける。
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if #vim.api.nvim_tabpage_list_wins(0) > 1 then
          pcall(vim.api.nvim_win_close, winid, true)
        end
      end
    end)

    it("一覧の外のウィンドウへ移ると一覧が閉じる", function()
      -- ログやシェルを開くと一覧の裏にフロートが残り続けてしまう。
      local handle = assert(open_view("container"))

      enter_plain_window()

      assert.is_nil(lifecycle.get("container"), "ビューが解除されること")
      assert.is_false(vim.api.nvim_win_is_valid(handle.window.winid))
    end)

    it("一覧の外へ移るとイベントの購読も止まる", function()
      -- ウィンドウだけ閉じて購読が残ると docker events の子プロセスが漏れる。
      local handle = assert(open_view("container"))
      local subscription = assert(handle.subscription, "購読が張られていること")

      enter_plain_window()

      assert.is_false(subscription.is_alive())
    end)

    it("ヘルプを前面に開いても一覧は閉じない", function()
      -- BR-018: 上層を閉じたときに下層の内容とカーソル位置を残す。
      local handle = assert(open_view("container"))

      vim.api.nvim_set_current_win(handle.window.winid)
      lifecycle.dispatch_for_test(handle, "help")

      assert.is_truthy(lifecycle.get("container"), "一覧が残ること")
      assert.is_true(vim.api.nvim_win_is_valid(handle.window.winid))
    end)

    it("別種別の一覧へ辿っても元の一覧は閉じない", function()
      local handle = assert(open_view("container"))

      vim.api.nvim_set_current_win(handle.window.winid)
      lifecycle.dispatch_for_test(handle, "drilldown")
      vim.wait(500, function()
        return lifecycle.get("image") ~= nil
      end)

      assert.is_truthy(lifecycle.get("image"), "辿った先が開くこと")
      assert.is_truthy(lifecycle.get("container"), "元の一覧が残ること")
    end)

    it("プラグイン以外のフロートへ移っても一覧は閉じない", function()
      -- vim.ui.input をフロートで実装している環境で、確認プロンプトを出しただけで
      -- 一覧が消えないようにする。
      local handle = assert(open_view("container"))

      local bufnr = vim.api.nvim_create_buf(false, true)
      local prompt = vim.api.nvim_open_win(bufnr, true, {
        relative = "editor",
        width = 20,
        height = 1,
        row = 1,
        col = 1,
        style = "minimal",
      })

      assert.is_truthy(lifecycle.get("container"), "一覧が残ること")
      assert.is_true(vim.api.nvim_win_is_valid(handle.window.winid))
      vim.api.nvim_win_close(prompt, true)
    end)

    it("ヘルプを開いたまま一覧の外へ移ると両方とも閉じる", function()
      local handle = assert(open_view("container"))
      vim.api.nvim_set_current_win(handle.window.winid)
      lifecycle.dispatch_for_test(handle, "help")
      local help_winid = vim.api.nvim_get_current_win()

      enter_plain_window()

      assert.is_false(vim.api.nvim_win_is_valid(help_winid), "ヘルプが閉じること")
      assert.is_false(vim.api.nvim_win_is_valid(handle.window.winid), "一覧も閉じること")
    end)

    it("複数の一覧を開いていても全て閉じて購読も止まる", function()
      -- 1 件だけ閉じて残りを取りこぼすと、docker events の子プロセスが漏れる。
      local containers = assert(open_view("container"))
      local images = assert(open_view("image"))
      local subscriptions = {
        assert(containers.subscription, "container の購読が張られていること"),
        assert(images.subscription, "image の購読が張られていること"),
      }

      enter_plain_window()

      assert.are.same({ false, false }, {
        subscriptions[1].is_alive(),
        subscriptions[2].is_alive(),
      })
      assert.is_false(vim.api.nvim_win_is_valid(containers.window.winid))
      assert.is_false(vim.api.nvim_win_is_valid(images.window.winid))
    end)

    it("フロートへフォーカスがあるまま最後の一覧を閉じても監視が残らない", function()
      -- 閉じたことで起きるフォーカス移動に後始末を任せると、移動先が
      -- プラグインのフロートだったときに監視だけが常駐する。
      local handle = assert(open_view("container"))
      vim.api.nvim_set_current_win(handle.window.winid)
      lifecycle.dispatch_for_test(handle, "help")

      lifecycle.close("container")

      assert.is_nil(lifecycle.get("container"))
      assert.are.same({}, vim.api.nvim_get_autocmds({ group = "DockerNvimViewFocus" }))
    end)

    it("qで一覧を1つ閉じても残っている一覧の監視は続く", function()
      local containers = assert(open_view("container"))
      local images = assert(open_view("image"))

      vim.api.nvim_set_current_win(containers.window.winid)
      lifecycle.dispatch_for_test(containers, "close")
      enter_plain_window()

      assert.is_nil(lifecycle.get("image"), "残っていた一覧も外へ移れば閉じること")
      assert.is_false(vim.api.nvim_win_is_valid(images.window.winid))
    end)

    it("コンテナ内のファイルを開いた後でも一覧を開き直せる", function()
      -- 一覧のフロートのバッファを差し替えると、bufhidden=wipe の一覧バッファが
      -- 破棄されたままウィンドウだけが残り、以後 open が「既存ビューへ移動」に
      -- 捕まって一覧が二度と描画されなくなる。
      local file_edit = require("docker.handlers.file_edit")
      local handle = assert(open_view("container"))
      local original_input = vim.ui.input
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        on_confirm("/etc/hosts")
      end
      -- `cp` だけ横取りし、一覧の取得は既定の偽 docker のまま通す。
      cli._set_executor(function(cmd, opts, on_exit)
        if cmd[2] == "cp" then
          vim.fn.writefile({ "127.0.0.1 localhost" }, cmd[4])
          on_exit({ code = 0, stdout = "", stderr = "" })
          return
        end
        fake_docker(cmd, opts, on_exit)
      end)

      vim.api.nvim_set_current_win(handle.window.winid)
      lifecycle.dispatch_for_test(handle, "edit_file")
      assert(
        vim.wait(3000, function()
          return vim.bo.buftype == "acwrite"
        end),
        "編集バッファが開かなかった"
      )
      vim.ui.input = original_input
      local edit_bufnr = vim.api.nvim_get_current_buf()

      -- 一覧は閉じ、開き直すと中身が描かれる。
      assert.is_nil(lifecycle.get("container"), "一覧が閉じること")
      local reopened = assert(open_view("container"))
      local lines = vim.api.nvim_buf_get_lines(reopened.window.bufnr, 0, -1, false)
      assert.is_truthy(lines[1]:find("web", 1, true), lines[1])

      file_edit._reset()
      vim.api.nvim_buf_delete(edit_bufnr, { force = true })
    end)

    it("ビューを閉じた後はウィンドウ移動の監視が残らない", function()
      -- 常駐すると一覧を開いていない間もウィンドウ移動のたびに走ってしまう。
      open_view("container")

      lifecycle.close_all()

      local watchers = vim.api.nvim_get_autocmds({ group = "DockerNvimViewFocus" })
      assert.are.same({}, watchers)
    end)

    it("閉じた後にもう一度開いても外れたときに閉じる", function()
      open_view("container")
      lifecycle.close_all()

      local handle = assert(open_view("container"))
      enter_plain_window()

      assert.is_nil(lifecycle.get("container"))
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

  describe("ドリルダウン", function()
    ---@param cmd_handler fun(cmd: string[]): string
    local function stub_lists(cmd_handler)
      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "version" then
          on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
          return
        end
        on_exit({ code = 0, stdout = cmd_handler(cmd), stderr = "" })
      end)
    end

    local function container_json(over)
      return vim.json.encode(vim.tbl_extend("force", {
        id = "c1",
        name = "web",
        image = "alpine",
        state = "running",
        status = "Up",
        ports = "",
        command = "x",
        created_at = "now",
        compose_project = "",
        compose_service = "",
        compose_oneoff = "",
      }, over or {}))
    end

    local function image_json(over)
      return vim.json.encode(vim.tbl_extend("force", {
        id = "i1",
        repository = "alpine",
        tag = "latest",
        created_since = "1d",
        size = "5MB",
      }, over or {}))
    end

    it("コンテナからそのイメージへ移り対象行にカーソルが当たる", function()
      stub_lists(function(cmd)
        if cmd[2] == "image" then
          return image_json({ id = "i0", repository = "other", tag = "1" })
            .. "\n"
            .. image_json({ id = "i1", repository = "alpine", tag = "latest" })
        end
        return container_json({ image = "alpine" })
      end)
      local handle = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 0 })

      lifecycle.dispatch_for_test(handle, "drilldown")
      assert(vim.wait(3000, function()
        return lifecycle.get("image") ~= nil
      end))

      local images = assert(lifecycle.get("image"))
      -- `docker ps` の .Image はタグ省略形 ("alpine") になることがある。
      assert.are.equal(2, vim.api.nvim_win_get_cursor(images.window.winid)[1], "alpine の行に当たること")
    end)

    it("イメージからそれを使うコンテナへ移る", function()
      stub_lists(function(cmd)
        if cmd[2] == "image" then
          return image_json({ repository = "alpine", tag = "3.20" })
        end
        return container_json({ id = "c0", name = "other", image = "nginx" })
          .. "\n"
          .. container_json({ id = "c1", name = "target", image = "alpine:3.20" })
      end)
      local handle = assert(open_view("image"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 0 })

      lifecycle.dispatch_for_test(handle, "drilldown")
      assert(vim.wait(3000, function()
        return lifecycle.get("container") ~= nil
      end))

      local containers = assert(lifecycle.get("container"))
      assert.are.equal(2, vim.api.nvim_win_get_cursor(containers.window.winid)[1])
    end)

    it("辿れる先が無いときは警告して開かない", function()
      stub_lists(function()
        return container_json({ image = "" })
      end)
      local handle = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 0 })

      lifecycle.dispatch_for_test(handle, "drilldown")
      vim.wait(300)

      assert.is_nil(lifecycle.get("image"))
      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
    end)
  end)

  describe("一括削除", function()
    ---@param count integer
    local function stub_containers(count)
      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "version" then
          on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
          return
        end
        if cmd[2] == "rm" then
          on_exit({ code = 0, stdout = "", stderr = "" })
          return
        end
        local rows = {}
        for i = 1, count do
          table.insert(
            rows,
            vim.json.encode({
              id = "id" .. i,
              name = "c" .. i,
              image = "alpine",
              state = "exited",
              status = "Exited",
              ports = "",
              command = "x",
              created_at = "now",
              compose_project = "",
              compose_service = "",
              compose_oneoff = "",
            })
          )
        end
        on_exit({ code = 0, stdout = table.concat(rows, "\n"), stderr = "" })
      end)
    end

    it("Visual モードにも削除のキーが張られる", function()
      -- ノーマルモードだけだと、範囲を選んで押してもプラグインに届かない。
      stub_containers(3)
      local handle = assert(open_view("container"))

      local visual = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(handle.window.bufnr, "x")) do
        visual[m.lhs] = true
      end

      assert.is_true(visual["D"], "Visual に D が張られていること")
    end)

    it("選択範囲の件数を確認プロンプトに出す", function()
      stub_containers(3)
      local handle = assert(open_view("container"))
      local prompts = {}
      local original_input = vim.ui.input
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(opts, on_confirm)
        table.insert(prompts, opts.prompt)
        on_confirm("n")
      end

      vim.api.nvim_set_current_win(handle.window.winid)
      vim.cmd("normal! ggVjj")
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("D", true, false, true), "x", false)
      vim.wait(300)
      vim.ui.input = original_input

      assert.are.equal(1, #prompts, "確認が 1 回出ること")
      assert.is_truthy(prompts[1]:find("3", 1, true), prompts[1])
    end)

    it("確認でyと答えると選択した件数ぶん削除する", function()
      stub_containers(3)
      local handle = assert(open_view("container"))
      local removed = {}
      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "rm" then
          table.insert(removed, cmd[3])
          on_exit({ code = 0, stdout = "", stderr = "" })
          return
        end
        on_exit({ code = 0, stdout = "", stderr = "" })
      end)
      local original_input = vim.ui.input
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        on_confirm("y")
      end

      vim.api.nvim_set_current_win(handle.window.winid)
      vim.cmd("normal! ggVj")
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("D", true, false, true), "x", false)
      vim.wait(500)
      vim.ui.input = original_input

      table.sort(removed)
      assert.are.same({ "id1", "id2" }, removed)
    end)

    it("確認でnと答えると1件も削除しない", function()
      stub_containers(3)
      local handle = assert(open_view("container"))
      local removed = {}
      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "rm" then
          table.insert(removed, cmd[3])
        end
        on_exit({ code = 0, stdout = "", stderr = "" })
      end)
      local original_input = vim.ui.input
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        on_confirm("n")
      end

      vim.api.nvim_set_current_win(handle.window.winid)
      vim.cmd("normal! ggVj")
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("D", true, false, true), "x", false)
      vim.wait(300)
      vim.ui.input = original_input

      assert.are.same({}, removed)
    end)

    it("一部が失敗しても残りは削除し失敗分をまとめて知らせる", function()
      stub_containers(3)
      local handle = assert(open_view("container"))
      local removed = {}
      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "rm" then
          table.insert(removed, cmd[3])
          if cmd[3] == "id1" then
            on_exit({ code = 1, stdout = "", stderr = "container is running" })
          else
            on_exit({ code = 0, stdout = "", stderr = "" })
          end
          return
        end
        on_exit({ code = 0, stdout = "", stderr = "" })
      end)
      local original_input = vim.ui.input
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.ui.input = function(_, on_confirm)
        on_confirm("y")
      end

      vim.api.nvim_set_current_win(handle.window.winid)
      vim.cmd("normal! ggVj")
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("D", true, false, true), "x", false)
      vim.wait(500)
      vim.ui.input = original_input

      assert.are.equal(2, #removed, "失敗しても他は実行すること")
      local last = notified[#notified]
      assert.are.equal(vim.log.levels.ERROR, last.level)
      assert.is_truthy(last.msg:find("id1", 1, true) or last.msg:find("c1", 1, true), last.msg)
    end)
  end)

  describe("詳細ビューの対象", function()
    it("カーソル行のリソースを inspect する", function()
      -- 常に 1 行目を見る実装だと、別のコンテナの詳細を出してしまう。
      local inspected = {}
      cli._set_executor(function(cmd, _, on_exit)
        if cmd[2] == "version" then
          on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
          return
        end
        if cmd[2] == "inspect" then
          table.insert(inspected, cmd[3])
          on_exit({ code = 0, stdout = "[{}]", stderr = "" })
          return
        end
        local rows = {}
        for i = 1, 3 do
          table.insert(
            rows,
            vim.json.encode({
              id = "id" .. i,
              name = "c" .. i,
              image = "alpine",
              state = "running",
              status = "Up",
              ports = "",
              command = "x",
              created_at = "now",
              compose_project = "",
              compose_service = "",
              compose_oneoff = "",
            })
          )
        end
        on_exit({ code = 0, stdout = table.concat(rows, "\n"), stderr = "" })
      end)
      local handle = assert(open_view("container"))
      vim.api.nvim_win_set_cursor(handle.window.winid, { 2, 0 })

      lifecycle.dispatch_for_test(handle, "inspect")
      assert(vim.wait(3000, function()
        return #inspected > 0
      end))

      assert.are.same({ "id2" }, inspected)
    end)
  end)
end)
