local cli = require("docker.adapters.docker.cli")
local config = require("docker.config")
local docker = require("docker")
local lifecycle = require("docker.handlers.lifecycle")
local store = require("docker.state.store")

-- plenary がテストを走らせる子プロセスは --noplugin で起動するため、
-- 利用者環境では自動で読まれる plugin/docker.lua がここでは読まれない。
-- Ex コマンドと <Plug> マッピングを検証するために明示的に読み込む。
vim.cmd("runtime! plugin/docker.lua")

describe("docker", function()
  local notified
  local original_notify

  before_each(function()
    notified = {}
    docker._reset()
    config._reset()
    store._reset()
    lifecycle.close_all()
    original_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end
    cli._set_executor(function(cmd, _, on_exit)
      if cmd[2] == "version" then
        on_exit({ code = 0, stdout = "29.4.0\n", stderr = "" })
      else
        on_exit({
          code = 0,
          stderr = "",
          stdout = '{"id":"abc123","name":"web","image":"alpine","state":"running","status":"Up",'
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
    docker._reset()
    config._reset()
    store._reset()
  end)

  describe("setup", function()
    it("利用者設定を取り込む", function()
      docker.setup({ keymaps = { container_list = { start = "s" } } })

      assert.are.equal("s", config.get().keymaps.container_list.start)
    end)

    it("設定を渡さなくても動く", function()
      docker.setup()

      assert.are.equal("u", config.get().keymaps.container_list.start)
    end)

    describe("要求バージョン未満のNeovim", function()
      local original_version

      before_each(function()
        original_version = vim.version
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.version = function()
          return { major = 0, minor = 9, patch = 5 }
        end
      end)

      after_each(function()
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.version = original_version
      end)

      it("対応バージョンを示すメッセージを通知する", function()
        docker.setup()

        local last = notified[#notified]
        assert.are.equal(vim.log.levels.ERROR, last.level)
        assert.is_truthy(last.msg:find("0.10", 1, true), last.msg)
      end)

      it("以降の操作でビューを開かない", function()
        -- 機能を無効化し、どの操作でも実行時エラーを出さない。
        docker.setup()

        docker.open("containers")

        assert.is_nil(lifecycle.get("container"))
      end)
    end)
  end)

  describe("open", function()
    it("複数形のサブコマンドでビューを開く", function()
      docker.setup()

      docker.open("containers")

      assert.is_truthy(lifecycle.get("container"))
    end)

    it("種別名でもビューを開く", function()
      docker.setup()

      docker.open("container")

      assert.is_truthy(lifecycle.get("container"))
    end)

    it("未知のサブコマンドは使い方を示して開かない", function()
      docker.setup()

      docker.open("nonexistent")

      assert.is_nil(lifecycle.get("container"))
      local last = notified[#notified]
      assert.are.equal(vim.log.levels.WARN, last.level)
      assert.is_truthy(last.msg:find("使い方", 1, true), last.msg)
    end)

    it("引数なしでも使い方を示す", function()
      docker.setup()

      docker.open("")

      local last = notified[#notified]
      assert.is_truthy(last.msg:find("使い方", 1, true), last.msg)
      assert.is_truthy(last.msg:find("containers", 1, true), last.msg)
    end)
  end)

  describe("close", function()
    it("開いているビューを閉じる", function()
      docker.setup()
      docker.open("containers")

      docker.close()

      assert.is_nil(lifecycle.get("container"))
    end)
  end)

  describe("Ex コマンド", function()
    it("Dockerコマンドが登録されている", function()
      assert.is_truthy(vim.fn.exists(":Docker") == 2)
    end)

    it("Docker containers で一覧が開く", function()
      docker.setup()

      vim.cmd("Docker containers")

      assert.is_truthy(lifecycle.get("container"))
    end)

    it("未知のサブコマンドでは開かず使い方を示す", function()
      docker.setup()

      vim.cmd("Docker nonexistent")

      assert.is_nil(lifecycle.get("container"))
      assert.is_truthy(notified[#notified].msg:find("使い方", 1, true))
    end)
  end)

  describe("Plug マッピング", function()
    it("リソース種別ごとの Plug マッピングが公開されている", function()
      local maps = {}
      for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
        maps[m.lhs] = true
      end

      assert.is_true(maps["<Plug>(docker-containers)"] == true)
      assert.is_true(maps["<Plug>(docker-images)"] == true)
    end)
  end)
end)
