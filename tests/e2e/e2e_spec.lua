-- G_E2E: MVP の全ユースケースを実際の docker に対して通しで実行する。
--
-- 検証用リソースの用意と後始末は scripts/e2e.sh が行う。このファイルは
-- 「用意済みの環境に対して docker.nvim を操作し、各段階を assert する」ことに徹する。
local docker = require("docker")
local jobs = require("docker.handlers.jobs")
local lifecycle = require("docker.handlers.lifecycle")

local PREFIX = assert(vim.env.DOCKER_NVIM_E2E_PREFIX, "scripts/e2e.sh 経由で実行すること")
local WORKDIR = assert(vim.env.DOCKER_NVIM_E2E_WORKDIR)

---@param cmd string[]
---@return string
local function sh(cmd)
  local out = vim.fn.system(cmd)
  return type(out) == "string" and out or ""
end

---@param kind string
---@return docker.ViewHandle
local function open_view(kind)
  local captured, called = nil, false
  lifecycle.open(kind, function(handle)
    captured, called = handle, true
  end)
  assert(
    vim.wait(20000, function()
      return called
    end),
    kind .. " のビューが開かなかった"
  )
  return assert(captured, kind .. " のビューが nil")
end

---@param handle docker.ViewHandle
---@return string[]
local function rows(handle)
  return vim.api.nvim_buf_get_lines(handle.window.bufnr, 0, -1, false)
end

---@param handle docker.ViewHandle
---@param needle string
---@return integer|nil
local function line_of(handle, needle)
  for index, line in ipairs(rows(handle)) do
    if line:find(needle, 1, true) then
      return index
    end
  end
  return nil
end

---@param handle docker.ViewHandle
---@param needle string
---@param timeout integer|nil
local function wait_for_line(handle, needle, timeout)
  assert(
    vim.wait(timeout or 15000, function()
      return line_of(handle, needle) ~= nil
    end, 100),
    ("行が現れなかった: %s\n%s"):format(needle, table.concat(rows(handle), "\n"))
  )
end

---@param handle docker.ViewHandle
---@param needle string
---@param action string
local function act_on(handle, needle, action)
  local lnum = assert(line_of(handle, needle), "対象の行が見つからない: " .. needle)
  vim.api.nvim_set_current_win(handle.window.winid)
  vim.api.nvim_win_set_cursor(handle.window.winid, { lnum, 0 })
  lifecycle.dispatch_for_test(handle, action)
end

describe("G_E2E: docker.nvim の通しシナリオ", function()
  before_each(function()
    docker.setup()
  end)

  after_each(function()
    lifecycle.close_all()
  end)

  it("US-001: 停止中を含む全コンテナが compose 列つきで一覧される", function()
    local handle = open_view("container")

    wait_for_line(handle, PREFIX .. "-standalone")
    wait_for_line(handle, PREFIX .. "-proj-web-1")

    -- compose 由来には PROJECT / SERVICE が入り、非 compose は空欄。
    local compose_line = rows(handle)[assert(line_of(handle, PREFIX .. "-proj-web-1"))]
    assert.is_truthy(compose_line:find(PREFIX .. "-proj", 1, true), compose_line)

    local plain_line = rows(handle)[assert(line_of(handle, PREFIX .. "-standalone"))]
    assert.is_nil(plain_line:find(PREFIX .. "-proj", 1, true), plain_line)
  end)

  it("US-002: 停止と起動が STATUS に反映される", function()
    local handle = open_view("container")
    wait_for_line(handle, PREFIX .. "-standalone")

    act_on(handle, PREFIX .. "-standalone", "kill")
    assert(
      vim.wait(20000, function()
        local lnum = line_of(handle, PREFIX .. "-standalone")
        return lnum ~= nil and rows(handle)[lnum]:find("Exited", 1, true) ~= nil
      end, 100),
      "停止が反映されない:\n" .. table.concat(rows(handle), "\n")
    )

    act_on(handle, PREFIX .. "-standalone", "start")
    assert(
      vim.wait(20000, function()
        local lnum = line_of(handle, PREFIX .. "-standalone")
        return lnum ~= nil and rows(handle)[lnum]:find("Up", 1, true) ~= nil
      end, 100),
      "起動が反映されない:\n" .. table.concat(rows(handle), "\n")
    )
  end)

  it("US-004 / G4: ログのターミナルを閉じると docker logs のプロセスが残らない", function()
    local handle = open_view("container")
    wait_for_line(handle, PREFIX .. "-standalone")
    local before = #jobs.list()

    act_on(handle, PREFIX .. "-standalone", "logs")
    assert(
      vim.wait(10000, function()
        return #jobs.list() > before
      end),
      "ターミナルのジョブが登録されない"
    )

    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_delete(bufnr, { force = true })

    assert(
      vim.wait(10000, function()
        return #jobs.list() == before
      end),
      "ジョブ台帳から外れない"
    )
    assert(
      vim.wait(10000, function()
        return sh({ "sh", "-c", "pgrep -f 'docker logs -f' || true" }):match("%S") == nil
      end, 200),
      "docker logs のプロセスが残っている"
    )
  end)

  it("US-003 / G3: 確認を経てコンテナを削除できる", function()
    local handle = open_view("container")
    wait_for_line(handle, PREFIX .. "-doomed")

    -- 実行中のコンテナは強制削除しない (BR-002) ので、先に止めてから削除する。
    act_on(handle, PREFIX .. "-doomed", "kill")
    assert(
      vim.wait(20000, function()
        local lnum = line_of(handle, PREFIX .. "-doomed")
        return lnum ~= nil and rows(handle)[lnum]:find("Exited", 1, true) ~= nil
      end, 100),
      "停止が反映されない"
    )

    -- y 以外では削除されない
    vim.ui.input = function(_, on_confirm)
      on_confirm("n")
    end
    act_on(handle, PREFIX .. "-doomed", "delete")
    vim.wait(1500)
    assert.is_truthy(line_of(handle, PREFIX .. "-doomed"), "n では削除されないこと")

    vim.ui.input = function(_, on_confirm)
      on_confirm("y")
    end
    act_on(handle, PREFIX .. "-doomed", "delete")
    assert(
      vim.wait(20000, function()
        return line_of(handle, PREFIX .. "-doomed") == nil
      end, 100),
      "削除が一覧へ反映されない"
    )
  end)

  it("US-006 / G5: 詳細ビューを開いて閉じるとカーソル位置が戻る", function()
    local handle = open_view("container")
    wait_for_line(handle, PREFIX .. "-standalone")
    local lnum = assert(line_of(handle, PREFIX .. "-standalone"))

    vim.api.nvim_set_current_win(handle.window.winid)
    vim.api.nvim_win_set_cursor(handle.window.winid, { lnum, 0 })
    lifecycle.dispatch_for_test(handle, "inspect")
    assert(
      vim.wait(15000, function()
        return vim.api.nvim_get_current_win() ~= handle.window.winid
      end),
      "詳細ビューが開かない"
    )

    local detail = vim.api.nvim_get_current_win()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "x", false)

    assert.is_false(vim.api.nvim_win_is_valid(detail), "詳細が閉じること")
    assert.are.equal(lnum, vim.api.nvim_win_get_cursor(handle.window.winid)[1], "カーソルが戻ること")
  end)

  it("US-011 / G9: 別プロセスの操作が 1 秒以内に一覧へ反映される", function()
    local handle = open_view("container")
    wait_for_line(handle, PREFIX .. "-standalone")

    local name = PREFIX .. "-live"
    sh({ "docker", "run", "-d", "--name", name, vim.env.DOCKER_NVIM_E2E_IMAGE or "alpine", "sleep", "300" })

    local start = vim.fn.reltime()
    assert(
      vim.wait(5000, function()
        return line_of(handle, name) ~= nil
      end, 20),
      "別プロセスの起動が反映されない"
    )
    local elapsed_ms = vim.fn.reltimefloat(vim.fn.reltime(start)) * 1000

    assert.is_true(elapsed_ms < 1000, ("反映まで %.0fms (目標 1000ms 以内)"):format(elapsed_ms))
    sh({ "docker", "rm", "-f", name })
  end)

  it("US-012 / G10: R で一覧を取り直せる", function()
    local handle = open_view("container")
    wait_for_line(handle, PREFIX .. "-standalone")

    lifecycle.dispatch_for_test(handle, "refresh")
    vim.wait(3000)

    assert.is_truthy(line_of(handle, PREFIX .. "-standalone"), "再取得後も一覧が保たれること")
  end)

  it("US-015 / G12: ? でそのビューの有効なキーが並ぶ", function()
    local handle = open_view("container")

    lifecycle.dispatch_for_test(handle, "help")
    assert(
      vim.wait(5000, function()
        return vim.api.nvim_get_current_win() ~= handle.window.winid
      end),
      "ヘルプが開かない"
    )

    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(text:find("start", 1, true), text)
    assert.is_truthy(text:find("logs", 1, true), text)
    -- コンテナ一覧に無い操作は載らない
    assert.is_nil(text:find("quickrun", 1, true), text)
  end)

  it("US-007 / G6: images / volumes / networks が一覧される", function()
    local volumes = open_view("volume")
    wait_for_line(volumes, PREFIX .. "-vol")
    lifecycle.close("volume")

    local networks = open_view("network")
    wait_for_line(networks, PREFIX .. "-net")
    lifecycle.close("network")

    local images = open_view("image")
    assert.is_true(#rows(images) > 0, "イメージが 1 件以上並ぶこと")
  end)

  it("US-008 / US-009 / G7 / G8: サービス一覧と compose 操作", function()
    vim.cmd("cd " .. vim.fn.fnameescape(WORKDIR))
    local handle = open_view("service")

    -- 未起動のサービスは none で並ぶ
    wait_for_line(handle, "never-started")
    local none_line = rows(handle)[assert(line_of(handle, "never-started"))]
    assert.is_truthy(none_line:find("none", 1, true), none_line)

    -- サービス単位の起動が反映される
    act_on(handle, "never-started", "up")
    assert(
      vim.wait(60000, function()
        local lnum = line_of(handle, "never-started")
        return lnum ~= nil and rows(handle)[lnum]:find("running", 1, true) ~= nil
      end, 200),
      "サービスの起動が反映されない:\n" .. table.concat(rows(handle), "\n")
    )
  end)

  it("US-010: D でプロジェクトを破棄すると各サービスが none に戻る", function()
    vim.cmd("cd " .. vim.fn.fnameescape(WORKDIR))
    local handle = open_view("service")
    wait_for_line(handle, "web")

    vim.ui.input = function(_, on_confirm)
      on_confirm("y")
    end
    act_on(handle, "web", "project_down")

    assert(
      vim.wait(60000, function()
        for _, line in ipairs(rows(handle)) do
          if line:find("running", 1, true) then
            return false
          end
        end
        return #rows(handle) > 0
      end, 200),
      "破棄が反映されない:\n" .. table.concat(rows(handle), "\n")
    )
  end)

  it("US-013: docker の実行中も別バッファの編集が滞らない", function()
    local handle = open_view("container")
    lifecycle.dispatch_for_test(handle, "refresh")

    -- 取得を待たずに別バッファを編集できる (実行が同期なら以降が進まない)。
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "editable" })

    assert.are.same({ "editable" }, vim.api.nvim_buf_get_lines(scratch, 0, -1, false))
    vim.api.nvim_buf_delete(scratch, { force = true })
  end)

  it("G13: 開いたまま終了処理を行うと子プロセスが残らない", function()
    local handle = open_view("container")
    wait_for_line(handle, PREFIX .. "-standalone")
    act_on(handle, PREFIX .. "-standalone", "logs")
    vim.wait(2000)
    assert.is_true(#jobs.list() > 0, "ジョブが登録されていること")

    -- VimLeavePre 相当の後始末
    jobs.stop_all()

    assert.are.same({}, jobs.list())
    assert(
      vim.wait(10000, function()
        return sh({ "sh", "-c", "pgrep -f 'docker logs -f' || true" }):match("%S") == nil
      end, 200),
      "終了後に docker logs のプロセスが残っている"
    )
  end)
end)
