local cli = require("docker.adapters.docker.cli")
local config = require("docker.config")
local docker = require("docker")
local lifecycle = require("docker.handlers.lifecycle")
local store = require("docker.state.store")

-- The child process in which plenary runs the tests starts with --noplugin, so
-- plugin/docker.lua, which is loaded automatically in a user's environment, is not loaded here.
-- It is sourced explicitly in order to verify the Ex command and the <Plug> mappings.
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
    it("takes in the user's settings", function()
      docker.setup({ keymaps = { container_list = { start = "s" } } })

      assert.are.equal("s", config.get().keymaps.container_list.start)
    end)

    it("works even when no settings are passed", function()
      docker.setup()

      assert.are.equal("u", config.get().keymaps.container_list.start)
    end)

    describe("a Neovim below the required version", function()
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

      it("notifies a message stating the supported version", function()
        docker.setup()

        local last = notified[#notified]
        assert.are.equal(vim.log.levels.ERROR, last.level)
        assert.is_truthy(last.msg:find("0.10", 1, true), last.msg)
      end)

      it("opens no view on any later operation", function()
        -- The plugin is disabled, and no operation raises a runtime error.
        docker.setup()

        docker.open("containers")

        assert.is_nil(lifecycle.get("container"))
      end)
    end)
  end)

  describe("open", function()
    it("opens the view for a plural subcommand", function()
      docker.setup()

      docker.open("containers")

      assert.is_truthy(lifecycle.get("container"))
    end)

    it("opens the view for a kind name as well", function()
      docker.setup()

      docker.open("container")

      assert.is_truthy(lifecycle.get("container"))
    end)

    it("shows the usage and opens nothing for an unknown subcommand", function()
      docker.setup()

      docker.open("nonexistent")

      assert.is_nil(lifecycle.get("container"))
      local last = notified[#notified]
      assert.are.equal(vim.log.levels.WARN, last.level)
      assert.is_truthy(last.msg:find("使い方", 1, true), last.msg)
    end)

    it("shows the usage when no argument is given either", function()
      docker.setup()

      docker.open("")

      local last = notified[#notified]
      assert.is_truthy(last.msg:find("使い方", 1, true), last.msg)
      assert.is_truthy(last.msg:find("containers", 1, true), last.msg)
    end)
  end)

  describe("close", function()
    it("closes the open view", function()
      docker.setup()
      docker.open("containers")

      docker.close()

      assert.is_nil(lifecycle.get("container"))
    end)
  end)

  describe("the Ex command", function()
    it("registers the Docker command", function()
      assert.is_truthy(vim.fn.exists(":Docker") == 2)
    end)

    it("opens the list on Docker containers", function()
      docker.setup()

      vim.cmd("Docker containers")

      assert.is_truthy(lifecycle.get("container"))
    end)

    it("shows the usage without opening anything for an unknown subcommand", function()
      docker.setup()

      vim.cmd("Docker nonexistent")

      assert.is_nil(lifecycle.get("container"))
      assert.is_truthy(notified[#notified].msg:find("使い方", 1, true))
    end)
  end)

  describe("the Plug mappings", function()
    it("exposes a Plug mapping for each resource kind", function()
      local maps = {}
      for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
        maps[m.lhs] = true
      end

      assert.is_true(maps["<Plug>(docker-containers)"] == true)
      assert.is_true(maps["<Plug>(docker-images)"] == true)
    end)
  end)
end)
