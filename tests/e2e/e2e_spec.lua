-- G_E2E: MVP の全ユースケースを実際の docker に対して通しで実行する。
--
-- 検証用リソースの用意と後始末は scripts/e2e.sh が行う。このファイルは
-- 「用意済みの環境に対して docker.nvim を操作し、各段階を assert する」ことに徹する。
local docker = require("docker")
local jobs = require("docker.handlers.jobs")
local lifecycle = require("docker.handlers.lifecycle")

local PREFIX = assert(vim.env.DOCKER_NVIM_E2E_PREFIX, "scripts/e2e.sh 経由で実行すること")
--- 検証用のイメージ。タグ付きで渡されることもある。
local E2E_IMAGE = vim.env.DOCKER_NVIM_E2E_IMAGE or "alpine"

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

--- 台帳に載っているジョブ ID の集合。
--- 一覧を閉じると events の購読も外れるため、件数の増減ではなく
--- 「どの ID が増えたか」で判定する。
---@return table<integer, boolean>
local function job_set()
  local set = {}
  for _, id in ipairs(jobs.list()) do
    set[id] = true
  end
  return set
end

--- 台帳に新しく載ったジョブ ID。
---@param before table<integer, boolean>
---@return integer[]
local function jobs_added_since(before)
  local added = {}
  for _, id in ipairs(jobs.list()) do
    if not before[id] then
      table.insert(added, id)
    end
  end
  return added
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
    local before = job_set()

    act_on(handle, PREFIX .. "-standalone", "logs")
    assert(
      vim.wait(10000, function()
        return jobs_added_since(before)[1] ~= nil
      end),
      "ターミナルのジョブが登録されない"
    )

    -- ターミナルへフォーカスが移るので一覧のフロートは残らない。
    assert.is_nil(lifecycle.get("container"), "一覧が閉じること")
    assert.is_false(vim.api.nvim_win_is_valid(handle.window.winid))

    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_delete(bufnr, { force = true })

    assert(
      vim.wait(10000, function()
        return #jobs_added_since(before) == 0
      end),
      ("ジョブ台帳から外れない (残っているジョブ: %s)"):format(vim.inspect(jobs_added_since(before)))
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
    sh({ "docker", "run", "-d", "--name", name, E2E_IMAGE, "sleep", "300" })

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

    -- R が何もしなくても「一覧が残っている」だけなら通ってしまう。
    -- 別プロセスで作ったコンテナが R の後に現れることで、取り直しを確かめる。
    local name = PREFIX .. "-refresh"
    sh({ "docker", "create", "--name", name, E2E_IMAGE, "true" })
    -- events による自動更新と区別するため、購読を止めてから R を押す。
    assert(handle.subscription, "購読が張られていること").stop()
    vim.wait(300)
    assert.is_nil(line_of(handle, name), "購読を止めた状態では自動では現れないこと")

    lifecycle.dispatch_for_test(handle, "refresh")

    assert(
      vim.wait(15000, function()
        return line_of(handle, name) ~= nil
      end, 100),
      "R で取り直した一覧に現れること"
    )
    sh({ "docker", "rm", "-f", name })
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
    -- 0 件でも empty_text の 1 行が返るため、件数だけでは検証にならない。
    local image_rows = rows(images)
    assert.is_nil(
      image_rows[1]:find("イメージがありません", 1, true),
      "実データが並ぶこと: " .. image_rows[1]
    )
    -- イメージ一覧は REPOSITORY と TAG が別の列なので、タグを外した名前で探す。
    wait_for_line(images, (E2E_IMAGE:gsub(":.*$", "")))
  end)

  it("US-007: イメージを削除できる", function()
    -- 検証用に別名のタグを付け、それを消す (元のイメージは残す)。
    local tag = PREFIX .. "-img:v1"
    sh({ "docker", "tag", E2E_IMAGE, tag })

    local handle = open_view("image")
    wait_for_line(handle, PREFIX .. "-img")

    vim.ui.input = function(_, on_confirm)
      on_confirm("y")
    end
    act_on(handle, PREFIX .. "-img", "delete")

    assert(
      vim.wait(20000, function()
        return line_of(handle, PREFIX .. "-img") == nil
      end, 100),
      "削除が一覧へ反映されない"
    )
  end)

  it("US-008 / US-009 / G7 / G8: compose プロジェクトの外からサービス一覧と compose 操作", function()
    -- compose ファイルの無い場所から開く。プロジェクトの所在はコンテナの
    -- ラベルから逆算されるので、どのプロジェクトも一覧に並ぶ。
    vim.cmd("cd " .. vim.fn.fnameescape(vim.env.HOME or "/"))
    local handle = open_view("service")

    -- 2 つのプロジェクトが PROJECT 列付きで並ぶ
    wait_for_line(handle, PREFIX .. "-proj2")
    wait_for_line(handle, PREFIX .. "-proj ")

    -- 起動していないサービスも、ラベル経由で引いた定義から none で並ぶ
    wait_for_line(handle, "never-started")
    local none_line = rows(handle)[assert(line_of(handle, "never-started"))]
    assert.is_truthy(none_line:find("none", 1, true), none_line)

    -- サービス単位の起動が反映される (compose ファイルのある場所は行が持っている)
    act_on(handle, "never-started", "up")
    assert(
      vim.wait(60000, function()
        local lnum = line_of(handle, "never-started")
        return lnum ~= nil and rows(handle)[lnum]:find("running", 1, true) ~= nil
      end, 200),
      "サービスの起動が反映されない:\n" .. table.concat(rows(handle), "\n")
    )
  end)

  it("US-010: D で破棄されるのは行のプロジェクトだけ", function()
    vim.cmd("cd " .. vim.fn.fnameescape(vim.env.HOME or "/"))
    local handle = open_view("service")
    wait_for_line(handle, "web")
    wait_for_line(handle, "api")

    vim.ui.input = function(_, on_confirm)
      on_confirm("y")
    end
    act_on(handle, "web", "project_down")

    -- 破棄したプロジェクトのサービスは一覧から消える (定義を引く場所ごと無くなる)。
    assert(
      vim.wait(60000, function()
        return line_of(handle, PREFIX .. "-proj ") == nil
      end, 200),
      "破棄が反映されない:\n" .. table.concat(rows(handle), "\n")
    )

    -- もう一方のプロジェクトは巻き添えにならない。
    local api_line = rows(handle)[assert(line_of(handle, "api"), table.concat(rows(handle), "\n"))]
    assert.is_truthy(api_line:find("running", 1, true), api_line)
  end)

  it("US-013: docker の実行中も Neovim が止まらない", function()
    local cli = require("docker.adapters.docker.cli")

    -- 実際に時間のかかる docker 実行を投げ、その戻りより先に制御が返ることを確かめる。
    -- 同期実行なら、この assert の時点で既に完了しているはず。
    local finished = false
    cli.run({ "run", "--rm", E2E_IMAGE, "sleep", "2" }, function()
      finished = true
    end)

    assert.is_false(finished, "呼び出しが戻った時点で完了していないこと (非同期であること)")

    -- 実行中に別バッファを編集できる
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "editable" })
    assert.are.same({ "editable" }, vim.api.nvim_buf_get_lines(scratch, 0, -1, false))
    vim.api.nvim_buf_delete(scratch, { force = true })

    assert(
      vim.wait(20000, function()
        return finished
      end, 100),
      "最終的には完了すること"
    )
  end)

  it("US-005: シェルを開ける / 停止中のコンテナでは開かない", function()
    local handle = open_view("container")
    wait_for_line(handle, PREFIX .. "-standalone")
    local jobs_before = job_set()

    act_on(handle, PREFIX .. "-standalone", "shell")
    assert(
      vim.wait(10000, function()
        return jobs_added_since(jobs_before)[1] ~= nil
      end),
      "実行中のコンテナでシェルが開くこと"
    )
    vim.api.nvim_buf_delete(vim.api.nvim_get_current_buf(), { force = true })
    vim.wait(500)

    -- 停止中のコンテナでは開かない (BR-007)
    local stopped = PREFIX .. "-stopped"
    sh({ "docker", "create", "--name", stopped, E2E_IMAGE, "true" })
    -- シェルへ移った時点で一覧は閉じているので開き直す。
    handle = open_view("container")
    wait_for_line(handle, stopped)

    local before = job_set()
    act_on(handle, stopped, "shell")
    vim.wait(1500)

    assert.are.same({}, jobs_added_since(before), "停止中のコンテナではシェルを開かないこと")
    sh({ "docker", "rm", "-f", stopped })
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
