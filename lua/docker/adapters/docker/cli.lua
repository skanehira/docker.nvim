--- docker コマンドの実行 (単発)。
---
--- 外界に触れるのはこのモジュールだけで、実行そのものは差し替え可能な実行器に委ねる。
--- 例外は投げず、常に `docker.Result` を返して呼び出し側に成否の検査を強制する。
local format = require("docker.adapters.docker.format")
local notify = require("docker.notify")

local M = {}

---@class docker.Result
---@field ok boolean
---@field data any          成功時の解析済みデータ
---@field error string|nil  失敗時のメッセージ (docker の stderr をそのまま入れる)
---@field code integer|nil  終了コード

---@alias docker.Executor fun(cmd: string[], opts: table, on_exit: fun(out: table))

--- docker が見つからないときに合成する stderr。
--- `vim.system` は実行ファイルが無いと同期的に例外を投げるだけで終了コードを返さないため、
--- 環境エラーの判定に載せられるようこの文言へ寄せる。
local EXECUTABLE_NOT_FOUND = "docker: executable not found"

local MESSAGE_NOT_INSTALLED =
  "docker コマンドが見つかりません。docker をインストールし PATH を通してください。"
local MESSAGE_DAEMON_DOWN =
  "docker デーモンに接続できません。docker が起動しているか確認してください。"
local MESSAGE_NO_PERMISSION =
  "docker ソケットへのアクセス権限がありません。ユーザーが docker グループに属しているか確認してください。"

---@param haystack string
---@param needle string
---@return boolean
local function contains(haystack, needle)
  return haystack:find(needle, 1, true) ~= nil
end

--- docker の接続先を指す語。権限エラーが docker の文脈で起きたことの確認に使う。
--- docker 29 は "docker API"、28 以前は "Docker daemon socket" を含む文言を出す。
local DOCKER_ENDPOINT_HINTS = { "docker api", "docker daemon socket", "docker.sock", "docker_engine" }

---@param stderr string
---@return boolean
local function mentions_docker_endpoint(stderr)
  for _, hint in ipairs(DOCKER_ENDPOINT_HINTS) do
    if contains(stderr, hint) then
      return true
    end
  end
  return false
end

--- 環境エラーの判定。終了コードだけでは区別できないため stderr の内容で分ける。
--- 上から順に評価する。
---
--- docker のバージョンで文言が変わる点に注意 (いずれも実機で採取):
---   28 以前 デーモン未起動: "Cannot connect to the Docker daemon at unix://... Is the docker daemon running?"
---   29     デーモン未起動: "failed to connect to the docker API at unix://...; check if the path is
---                          correct and if the daemon is running: ... connect: no such file or directory"
---   28 以前 権限不足:     "Got permission denied while trying to connect to the Docker daemon socket at ..."
---   29     権限不足:     "permission denied while trying to connect to the docker API at unix://..."
--- 新しい文言だけに合わせると古い docker で、古い文言だけに合わせると新しい docker で
--- 判定が黙って効かなくなるため、両方を受ける。
local ENVIRONMENT_ERRORS = {
  {
    -- 権限不足は docker の接続先に言及していることまで確認する。
    -- `permission denied` だけで判定すると、SSH 越しの docker context が返す
    -- `Permission denied (publickey).` を docker グループの問題として誤案内してしまう。
    matches = function(stderr)
      return contains(stderr, "permission denied") and mentions_docker_endpoint(stderr)
    end,
    message = MESSAGE_NO_PERMISSION,
  },
  {
    matches = function(stderr)
      return contains(stderr, "executable not found") or contains(stderr, "command not found")
    end,
    message = MESSAGE_NOT_INSTALLED,
  },
  {
    matches = function(stderr)
      -- 28 以前と 29 で 1 つずつ。どちらの文言も片方だけに一致するので、
      -- 片方を落とせば対応するテストが落ちる (冗長な別名を並べない)。
      return contains(stderr, "cannot connect to the docker daemon")
        or contains(stderr, "failed to connect to the docker api")
    end,
    message = MESSAGE_DAEMON_DOWN,
  },
}

---@type docker.Executor|nil
local executor = nil

--- 既定の実行器。vim.system による非同期実行。
--- docker 自体が見つからない場合、vim.system は終了コードではなく例外を投げる。
--- 呼び出し側に例外を伝播させると `docker.Result` の契約が崩れるため、ここで
--- 終了コード 127 の結果へ変換する (8.3 の「pcall は vim.json.decode に限る」の唯一の例外)。
---@type docker.Executor
local function default_executor(cmd, opts, on_exit)
  -- 起動失敗の結果は必ず次のイベントループで返す。ここだけ同期で返すと、
  -- 先に発行した実行より後から発行した失敗が先に配送され、呼び出し順と
  -- 配送順が入れ替わる (「cli.run の後にフラグを立てる」書き方が壊れる)。
  local function fail(stderr)
    vim.schedule(function()
      on_exit({ code = 127, stdout = "", stderr = stderr })
    end)
  end

  -- 起動に失敗する理由は docker 不在だけではない。作業ディレクトリが無い場合も
  -- 同じ経路で失敗するため、「docker をインストールしてください」と誤案内しない。
  -- 例外メッセージから判別すると Neovim のバージョンで文言が変わるので、事実を直接確かめる。
  if opts.cwd and vim.fn.isdirectory(opts.cwd) == 0 then
    fail("docker: working directory not found (" .. tostring(opts.cwd) .. ")")
    return
  end

  local ok, err = pcall(vim.system, cmd, { text = true, cwd = opts.cwd }, function(out)
    on_exit(out)
  end)
  if not ok then
    fail(EXECUTABLE_NOT_FOUND .. " (" .. tostring(err) .. ")")
  end
end

--- 結果の配送をメインループ上で行う。
--- `vim.system` の on_exit は fast event context で呼ばれ、そこでは `vim.notify` を含む
--- 多くの API が `E5560` で失敗する。呼び出し側 (通知・描画) が必ずこの制約に当たるため、
--- 境界であるアダプタ層で吸収する。同期的な偽の実行器を使うテストでは
--- fast event ではないためそのまま実行され、逐次的に検証できる。
---@param fn fun()
local function deliver(fn)
  if vim.in_fast_event() then
    vim.schedule(fn)
  else
    fn()
  end
end

--- テスト用の差し替え口。nil を渡すと既定の実行器に戻る。
---@param fn docker.Executor|nil
function M._set_executor(fn)
  executor = fn
end

---@param s string|nil
---@return string
local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param stdout string
---@param parse string|nil
---@return string|nil error  解析できなかった理由 (成功時は nil)
---@return any data
local function parse_output(stdout, parse)
  if parse == "ndjson" then
    local items, skipped = format.parse_ndjson(stdout)
    if skipped > 0 then
      notify.debug(string.format("skipped %d unparsable line(s)", skipped))
      -- 1 行も解析できなかった場合は「0 件」と区別できないためエラーとして扱う。
      if #items == 0 then
        return string.format("failed to parse all %d line(s) of docker output", skipped), nil
      end
    end
    return nil, items
  end

  if parse == "json" then
    if not trim(stdout):match("%S") then
      return nil, nil
    end
    local ok, decoded = pcall(vim.json.decode, stdout)
    -- `{{json .X}}` は値が無いフィールドに null を出すため、オブジェクトや配列以外が
    -- 返ることが実際にある。呼び出し側が data をテーブルとして扱えるようここで弾く
    -- (ndjson 側の行単位の判定と揃える)。
    if not ok or type(decoded) ~= "table" then
      return "failed to parse docker output", nil
    end
    return nil, decoded
  end

  return nil, stdout
end

--- docker を実行して結果を `docker.Result` で返す。
---@param args string[] docker に渡す引数 ("docker" 自体は含めない)
---@param on_done fun(result: docker.Result)
---@param opts { parse: "ndjson"|"json"|"raw"|nil, cwd: string|nil }|nil
function M.run(args, on_done, opts)
  opts = opts or {}
  local cmd = { "docker" }
  vim.list_extend(cmd, args)

  local run_with = executor or default_executor
  run_with(cmd, { cwd = opts.cwd }, function(out)
    deliver(function()
      local code = out and out.code
      local signal = out and out.signal

      if notify.is_debug() then
        notify.debug(string.format("%s (exit %s)", table.concat(cmd, " "), tostring(code)))
      end

      -- 終了コードを報告しない実行結果は成功と見なせない。
      if type(code) ~= "number" then
        on_done({ ok = false, data = nil, error = "docker did not report an exit code", code = nil })
        return
      end

      -- シグナルで終了したプロセスは終了コード 0 を返すことがある。
      -- そのまま成功として扱うと、途中で切れた出力を「全件」と解釈してしまう。
      if type(signal) == "number" and signal ~= 0 then
        on_done({
          ok = false,
          data = nil,
          error = string.format("docker was terminated by signal %d", signal),
          code = code,
        })
        return
      end

      if code ~= 0 then
        local message = trim(out.stderr)
        if message == "" then
          message = string.format("docker exited with code %d", code)
        end
        on_done({ ok = false, data = nil, error = message, code = code })
        return
      end

      local parse_error, data = parse_output(out.stdout or "", opts.parse)
      if parse_error then
        on_done({ ok = false, data = nil, error = parse_error, code = code })
        return
      end

      on_done({ ok = true, data = data, error = nil, code = code })
    end)
  end)
end

--- デーモンへ接続できるかを確認する。
--- 失敗時は「docker 未検出」「デーモン未起動」「ソケット権限不足」を区別した文言を返す。
---@param on_done fun(result: docker.Result)
function M.check_connection(on_done)
  M.run({ "version", "--format", "{{.Server.Version}}" }, function(result)
    if result.ok then
      on_done({ ok = true, data = trim(result.data), error = nil, code = result.code })
      return
    end

    local stderr = tostring(result.error or ""):lower()
    for _, known in ipairs(ENVIRONMENT_ERRORS) do
      if known.matches(stderr) then
        on_done({ ok = false, data = nil, error = known.message, code = result.code })
        return
      end
    end

    on_done(result)
  end)
end

return M
