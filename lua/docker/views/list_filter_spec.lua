local cli = require("docker.adapters.docker.cli")
local config = require("docker.config")
local events = require("docker.adapters.docker.events")
local jobs = require("docker.handlers.jobs")
local lifecycle = require("docker.handlers.lifecycle")
local store = require("docker.state.store")

describe("一覧の絞り込み", function()
  local original_input

  before_each(function()
    config._reset()
    store._reset()
    jobs._reset()
    jobs._set_stopper(function() end)
    lifecycle.close_all()
    original_input = vim.ui.input
    cli._set_executor(function(cmd, _, on_exit)
      if cmd[2] == "version" then
        on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
        return
      end
      local rows = {}
      for _, spec in ipairs({
        { id = "1", name = "web-server", image = "nginx" },
        { id = "2", name = "database", image = "postgres" },
        { id = "3", name = "cache", image = "redis" },
      }) do
        table.insert(
          rows,
          vim.json.encode({
            id = spec.id,
            name = spec.name,
            image = spec.image,
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
    events._set_starter(function()
      return 900
    end)
    events._set_waiter(function() end)
  end)

  after_each(function()
    lifecycle.close_all()
    vim.ui.input = original_input
    cli._set_executor(nil)
    events._set_starter(nil)
    events._set_waiter(nil)
    jobs._reset()
    config._reset()
    store._reset()
  end)

  ---@return docker.ViewHandle
  local function open_view()
    local captured, called = nil, false
    lifecycle.open("container", function(handle)
      captured, called = handle, true
    end)
    assert(vim.wait(3000, function()
      return called
    end))
    return assert(captured)
  end

  ---@param text string|nil
  local function answer_filter(text)
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.input = function(_, on_confirm)
      on_confirm(text)
    end
  end

  ---@param handle docker.ViewHandle
  ---@return string[]
  local function lines(handle)
    return vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false)
  end

  it("絞り込む前は全件が並ぶ", function()
    local handle = open_view()

    assert.are.equal(3, #lines(handle))
  end)

  it("部分一致する行だけが表示される", function()
    local handle = open_view()
    answer_filter("web")

    lifecycle.dispatch_for_test(handle, "filter")

    local shown = lines(handle)
    assert.are.equal(1, #shown)
    assert.is_truthy(shown[1]:find("web-server", 1, true), shown[1])
  end)

  it("名前以外の列にも一致する", function()
    local handle = open_view()
    answer_filter("postgres")

    lifecycle.dispatch_for_test(handle, "filter")

    local shown = lines(handle)
    assert.are.equal(1, #shown)
    assert.is_truthy(shown[1]:find("database", 1, true), shown[1])
  end)

  it("空文字を入れると全行に戻る", function()
    local handle = open_view()
    answer_filter("web")
    lifecycle.dispatch_for_test(handle, "filter")
    assert.are.equal(1, #lines(handle))

    answer_filter("")
    lifecycle.dispatch_for_test(handle, "filter")

    assert.are.equal(3, #lines(handle))
  end)

  it("入力をキャンセルすると絞り込みは変わらない", function()
    local handle = open_view()
    answer_filter("web")
    lifecycle.dispatch_for_test(handle, "filter")

    answer_filter(nil)
    lifecycle.dispatch_for_test(handle, "filter")

    assert.are.equal(1, #lines(handle))
  end)

  it("一致しないときは0件の表示になる", function()
    local handle = open_view()
    answer_filter("zzz-no-match")

    lifecycle.dispatch_for_test(handle, "filter")

    assert.are.same({ "コンテナがありません" }, lines(handle))
  end)

  it("絞り込み中の操作は表示されている行の対象に効く", function()
    -- 行と項目の対応がずれると、別のコンテナを操作してしまう。
    local handle = open_view()
    answer_filter("cache")
    lifecycle.dispatch_for_test(handle, "filter")

    local runs = {}
    cli._set_executor(function(cmd, _, on_exit)
      table.insert(runs, cmd)
      on_exit({ code = 0, stdout = "", stderr = "" })
    end)
    vim.api.nvim_win_set_cursor(handle.window.winid, { 1, 0 })
    lifecycle.dispatch_for_test(handle, "stop")

    assert.are.same({ "docker", "stop", "3" }, runs[1], "絞り込み後の 1 行目 (cache) が対象になること")
  end)

  it("絞り込みのキーは Ctrl-f で / は奪わない", function()
    -- `/` は Neovim 本来の検索として残す。
    local handle = open_view()

    local mapped = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(handle.window.bufnr, "n")) do
      mapped[m.lhs] = true
    end

    assert.is_true(mapped["<C-F>"] or mapped["<C-f>"], "Ctrl-f が割り当てられていること")
    assert.is_nil(mapped["/"], "/ は割り当てないこと")
  end)
end)
