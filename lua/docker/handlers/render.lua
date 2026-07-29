--- 描画要求の集約とデバウンス。
---
--- `docker events` にはデーモン全体のイベントが流れる (他プロセスの操作も混入する)。
--- まとめずに描画すると、`docker compose up` のような一斉変更のたびに空回りする。
local M = {}

--- 待ち時間。フェーズ4 の実測で確定した値。
--- 目標はイベント受信から反映まで 1 秒 (G9)。内訳は
--- 「デバウンス 100ms + 対象の再取得 20〜60ms + 描画 2ms」で約 850ms の余裕が残る。
M.DELAY_MS = 100

---@class docker.RenderTimer
---@field stop fun()

---@type (fun(delay: integer, callback: fun()): docker.RenderTimer)|nil
local timer_factory = nil

--- キー -> 待機中のタイマー
---@type table<string, docker.RenderTimer>
local pending = {}

--- テスト用の差し替え口。nil を渡すと実際のタイマーに戻る。
---@param factory (fun(delay: integer, callback: fun()): docker.RenderTimer)|nil
function M._set_timer_factory(factory)
  timer_factory = factory
end

--- テスト用。待機中の要求を捨てる。
function M._reset()
  for key, timer in pairs(pending) do
    timer.stop()
    pending[key] = nil
  end
  pending = {}
end

---@param delay integer
---@param callback fun()
---@return docker.RenderTimer
local function default_timer(delay, callback)
  -- `vim.defer_fn` のコールバックはメインループ上で走る。
  -- 取り消しはタイマーを止めるのではなくフラグで行う (待機中のタイマーが 1 つ
  -- 空振りするだけで、待ち時間は 100ms と短く実害が無い)。
  local cancelled = false
  vim.defer_fn(function()
    if not cancelled then
      callback()
    end
  end, delay)
  return {
    stop = function()
      cancelled = true
    end,
  }
end

--- 描画を要求する。同じキーの連続した要求は 1 回にまとめる。
--- まとめられた場合、最後に渡した描画が実行される (最新の状態を描くため)。
---@param key string
---@param draw fun()
function M.request(key, draw)
  M.cancel(key)

  local create = timer_factory or default_timer
  pending[key] = create(M.DELAY_MS, function()
    pending[key] = nil
    draw()
  end)
end

--- 待機中の描画要求を取り消す。
---@param key string
function M.cancel(key)
  local timer = pending[key]
  if timer then
    timer.stop()
    pending[key] = nil
  end
end

return M
