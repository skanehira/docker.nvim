local cli = require("docker.adapters.docker.cli")
local config = require("docker.config")
local lifecycle = require("docker.handlers.lifecycle")
local store = require("docker.state.store")

describe("docker.handlers.lifecycle", function()
  local notified
  local original_notify

  before_each(function()
    notified = {}
    config._reset()
    store._reset()
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

  after_each(function()
    lifecycle.close_all()
    vim.notify = original_notify
    cli._set_executor(nil)
    config._reset()
    store._reset()
  end)

  describe("open", function()
    it("一覧ビューを開く", function()
      local handle = lifecycle.open("container")

      assert.is_truthy(handle)
      handle = assert(handle)
      assert.is_true(vim.api.nvim_win_is_valid(handle.window.winid))
    end)

    it("取得した内容をバッファへ描画する", function()
      local handle = assert(lifecycle.open("container"))

      local lines = vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false)
      assert.is_truthy(lines[1]:find("web", 1, true), lines[1])
    end)

    it("同じ種別を再度開くと新しいバッファを作らず既存へ移動する", function()
      -- US-026: 複数タブで開いてもバッファは 1 つに保つ。
      local first = assert(lifecycle.open("container"))

      local second = assert(lifecycle.open("container"))

      assert.are.equal(first.window.bufnr, second.window.bufnr)
    end)

    it("キーマップをバッファローカルに設定する", function()
      -- BR-014: 一覧ビュー以外のバッファでプラグインのキーが作用しない。
      local handle = assert(lifecycle.open("container"))

      local mapped = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(handle.window.bufnr, "n")) do
        mapped[m.lhs] = true
      end
      assert.is_true(mapped["u"], "start のキーが設定されていること")
      assert.is_true(mapped["q"], "close のキーが設定されていること")
    end)

    it("プラグインのキーは他のバッファには設定されない", function()
      lifecycle.open("container")

      local scratch = vim.api.nvim_create_buf(false, true)
      assert.are.same({}, vim.api.nvim_buf_get_keymap(scratch, "n"))
      vim.api.nvim_buf_delete(scratch, { force = true })
    end)

    it("未知の種別は開かずに警告する", function()
      local handle = lifecycle.open("nonexistent")

      assert.is_nil(handle)
      assert.are.equal(vim.log.levels.WARN, notified[#notified].level)
    end)

    it("dockerに接続できないときはビューを開かずエラーを通知する", function()
      cli._set_executor(function(_, _, on_exit)
        on_exit({ code = 1, stdout = "", stderr = "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" })
      end)

      local handle = lifecycle.open("container")

      assert.is_nil(handle)
      local last = notified[#notified]
      assert.are.equal(vim.log.levels.ERROR, last.level)
      assert.is_truthy(last.msg:find("デーモン", 1, true), last.msg)
    end)
  end)

  describe("close", function()
    it("ビューを閉じる", function()
      local handle = assert(lifecycle.open("container"))

      lifecycle.close("container")

      assert.is_false(vim.api.nvim_win_is_valid(handle.window.winid))
    end)

    it("閉じた後に開くと新しいバッファになる", function()
      local first = assert(lifecycle.open("container"))
      lifecycle.close("container")

      local second = assert(lifecycle.open("container"))

      assert.is_true(first.window.bufnr ~= second.window.bufnr)
    end)

    it("開いていない種別を閉じてもエラーにならない", function()
      lifecycle.close("container")
    end)
  end)

  describe("close_all", function()
    it("開いている全てのビューを閉じる", function()
      local handle = assert(lifecycle.open("container"))

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
      local handle = assert(lifecycle.open("container"))

      press(handle, "q")

      assert.is_nil(lifecycle.get("container"))
    end)

    it("?でヘルプが前面に開く", function()
      local handle = assert(lifecycle.open("container"))

      press(handle, "?")

      local current = vim.api.nvim_get_current_win()
      assert.is_true(current ~= handle.window.winid, "ヘルプのウィンドウへ移ること")
      local joined = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      assert.is_truthy(joined:find("start", 1, true), joined)
    end)

    it("Rで一覧を取り直す", function()
      local handle = assert(lifecycle.open("container"))
      local before = #vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false)

      press(handle, "R")

      assert.are.equal(before, #vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false))
    end)
  end)
end)
