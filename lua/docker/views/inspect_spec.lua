local cli = require("docker.adapters.docker.cli")
local inspect = require("docker.views.inspect")
local registry = require("docker.resources.registry")
local window = require("docker.ui.window")

describe("docker.views.inspect", function()
  local runs, notified
  local original_notify
  ---@type docker.ResourceDefinition
  local def
  local opened

  ---@param out table
  local function stub(out)
    cli._set_executor(function(cmd, _, on_exit)
      table.insert(runs, cmd)
      on_exit({ code = out.code, stdout = out.stdout or "", stderr = out.stderr or "" })
    end)
  end

  ---@return docker.Window|nil
  local function open_inspect(item)
    local captured, called = nil, false
    inspect.open(def, item, function(handle)
      captured, called = handle, true
    end)
    assert(vim.wait(3000, function()
      return called
    end))
    if captured then
      table.insert(opened, captured)
    end
    return captured
  end

  before_each(function()
    runs, notified, opened = {}, {}, {}
    def = assert(registry.get("container"))
    original_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end
  end)

  after_each(function()
    for _, handle in ipairs(opened) do
      window.close(handle)
    end
    vim.notify = original_notify
    cli._set_executor(nil)
  end)

  describe("open", function()
    it("対象のIDでdocker inspectを実行する", function()
      stub({ code = 0, stdout = "[{}]" })

      open_inspect({ id = "abc123", name = "web" })

      assert.are.same({ "docker", "inspect", "abc123" }, runs[1])
    end)

    it("dockerの整形済み出力をそのまま行として表示する", function()
      -- `docker inspect` は既に字下げ済みの JSON を返す。
      -- 解析し直して整形するとキーの順序が崩れるうえ外部の整形器が要る。
      stub({
        code = 0,
        stdout = table.concat({
          "[",
          "    {",
          '        "Id": "abc123",',
          '        "State": {',
          '            "Status": "running"',
          "        }",
          "    }",
          "]",
        }, "\n"),
      })

      local handle = assert(open_inspect({ id = "abc123", name = "web" }))

      assert.are.same({
        "[",
        "    {",
        '        "Id": "abc123",',
        '        "State": {',
        '            "Status": "running"',
        "        }",
        "    }",
        "]",
      }, vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false))
    end)

    it("タイトルに対象名を含める", function()
      stub({ code = 0, stdout = "[{}]" })

      local handle = assert(open_inspect({ id = "abc123", name = "web" }))

      local title = vim.api.nvim_win_get_config(handle.winid).title[1][1]
      assert.is_truthy(title:find("web", 1, true), title)
    end)

    it("一覧より前面に重ねる", function()
      -- 閉じたときに下層の一覧とカーソル位置がそのまま残るようにする。
      stub({ code = 0, stdout = "[{}]" })
      local below = window.open({ title = "Containers", zindex = 50 })

      local handle = assert(open_inspect({ id = "abc123", name = "web" }))

      assert.is_true(vim.api.nvim_win_get_config(handle.winid).zindex > vim.api.nvim_win_get_config(below.winid).zindex)
      window.close(below)
    end)

    it("取得に失敗するとビューを開かずエラーを通知する", function()
      stub({ code = 1, stderr = "Error: No such object: nope" })

      local handle = open_inspect({ id = "nope", name = "nope" })

      assert.is_nil(handle)
      local last = notified[#notified]
      assert.are.equal(vim.log.levels.ERROR, last.level)
      assert.are.equal("Error: No such object: nope", last.msg)
    end)

    it("出力が解析できないときもビューを開かない", function()
      stub({ code = 0, stdout = "not json" })

      assert.is_nil(open_inspect({ id = "abc123", name = "web" }))
    end)

    it("バッファは書き込み対象にならない", function()
      stub({ code = 0, stdout = "[{}]" })

      local handle = assert(open_inspect({ id = "abc123", name = "web" }))

      assert.are.equal("nofile", vim.bo[handle.bufnr].buftype)
      assert.is_false(vim.bo[handle.bufnr].modifiable)
    end)

    it("JSONとして色付けできるようfiletypeを設定する", function()
      stub({ code = 0, stdout = "[{}]" })

      local handle = assert(open_inspect({ id = "abc123", name = "web" }))

      assert.are.equal("json", vim.bo[handle.bufnr].filetype)
    end)
  end)

  describe("閉じたときの復帰", function()
    it("qで閉じると下層の一覧とカーソル位置が残る", function()
      -- BR-018: 詳細を閉じると直前の一覧へ戻る。
      stub({ code = 0, stdout = "[{}]" })
      local below = window.open({ title = "Containers", zindex = 50 })
      window.set_lines(below, { "a", "b", "c", "d" })
      vim.api.nvim_set_current_win(below.winid)
      vim.api.nvim_win_set_cursor(below.winid, { 3, 0 })

      local handle = assert(open_inspect({ id = "abc123", name = "web" }))
      vim.api.nvim_set_current_win(handle.winid)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "x", false)

      assert.is_false(vim.api.nvim_win_is_valid(handle.winid), "詳細が閉じること")
      assert.is_true(vim.api.nvim_win_is_valid(below.winid), "一覧が残ること")
      assert.are.equal(3, vim.api.nvim_win_get_cursor(below.winid)[1], "カーソル位置が戻ること")
      window.close(below)
    end)
  end)
end)
