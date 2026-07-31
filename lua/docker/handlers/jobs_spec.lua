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
    it("puts a started job on the ledger", function()
      jobs.register(11)

      assert.are.same({ 11 }, jobs.list())
    end)

    it("keeps several jobs in registration order", function()
      jobs.register(11)
      jobs.register(22)

      assert.are.same({ 11, 22 }, jobs.list())
    end)

    it("does not register the same job twice", function()
      jobs.register(11)
      jobs.register(11)

      assert.are.same({ 11 }, jobs.list())
    end)
  end)

  describe("unregister", function()
    it("removes the job from the ledger", function()
      jobs.register(11)
      jobs.register(22)

      jobs.unregister(11)

      assert.are.same({ 22 }, jobs.list())
    end)

    it("does not stop a job that has been removed", function()
      jobs.register(11)
      jobs.register(22)
      jobs.unregister(11)

      jobs.stop_all()

      assert.are.same({ 22 }, stopped)
    end)

    it("does not error when removing a job that is not registered", function()
      jobs.register(11)

      jobs.unregister(99)

      assert.are.same({ 11 }, jobs.list())
    end)
  end)

  describe("stop_all", function()
    it("stops every registered job", function()
      jobs.register(11)
      jobs.register(22)

      jobs.stop_all()

      assert.are.same({ 11, 22 }, stopped)
    end)

    it("leaves the ledger empty after stopping", function()
      jobs.register(11)

      jobs.stop_all()

      assert.are.same({}, jobs.list())
    end)

    it("stops nothing when there is no job", function()
      jobs.stop_all()

      assert.are.same({}, stopped)
    end)
  end)

  describe("VimLeavePre", function()
    it("stops every job when Neovim exits", function()
      -- G13: running :qa with the list and a terminal still open leaves no child process behind.
      jobs.register(11)
      jobs.register(22)

      vim.api.nvim_exec_autocmds("VimLeavePre", {})

      assert.are.same({ 11, 22 }, stopped)
      assert.are.same({}, jobs.list())
    end)
  end)
end)
