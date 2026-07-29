local jobs = require("docker.handlers.jobs")

describe("docker.handlers.jobs", function()
  local stopped

  before_each(function()
    jobs._reset()
    stopped = {}
    jobs._set_stopper(function(job_id)
      table.insert(stopped, job_id)
    end)
  end)

  after_each(function()
    jobs._reset()
  end)

  describe("register", function()
    it("起動したジョブを台帳に載せる", function()
      jobs.register(11)

      assert.are.same({ 11 }, jobs.list())
    end)

    it("複数のジョブを登録順に保つ", function()
      jobs.register(11)
      jobs.register(22)

      assert.are.same({ 11, 22 }, jobs.list())
    end)

    it("同じジョブを二重に登録しない", function()
      jobs.register(11)
      jobs.register(11)

      assert.are.same({ 11 }, jobs.list())
    end)
  end)

  describe("unregister", function()
    it("台帳から取り除く", function()
      jobs.register(11)
      jobs.register(22)

      jobs.unregister(11)

      assert.are.same({ 22 }, jobs.list())
    end)

    it("取り除いたジョブは停止対象にならない", function()
      jobs.register(11)
      jobs.register(22)
      jobs.unregister(11)

      jobs.stop_all()

      assert.are.same({ 22 }, stopped)
    end)

    it("登録されていないジョブを取り除いてもエラーにならない", function()
      jobs.register(11)

      jobs.unregister(99)

      assert.are.same({ 11 }, jobs.list())
    end)
  end)

  describe("stop_all", function()
    it("登録された全ジョブを停止する", function()
      jobs.register(11)
      jobs.register(22)

      jobs.stop_all()

      assert.are.same({ 11, 22 }, stopped)
    end)

    it("停止後は台帳が空になる", function()
      jobs.register(11)

      jobs.stop_all()

      assert.are.same({}, jobs.list())
    end)

    it("ジョブが無いときは何も停止しない", function()
      jobs.stop_all()

      assert.are.same({}, stopped)
    end)
  end)

  describe("VimLeavePre", function()
    it("Neovim終了時に全ジョブが停止される", function()
      -- G13: 一覧とターミナルを開いたまま :qa しても子プロセスを残さない。
      jobs.register(11)
      jobs.register(22)

      vim.api.nvim_exec_autocmds("VimLeavePre", {})

      assert.are.same({ 11, 22 }, stopped)
      assert.are.same({}, jobs.list())
    end)
  end)
end)
