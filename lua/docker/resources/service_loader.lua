--- compose サービス一覧の取得。
---
--- サービス一覧は docker の単一コマンドで取れないため、compose の定義とコンテナ一覧を
--- 突き合わせて組み立てる (7.3)。多段の非同期を含むので、宣言的定義である registry から
--- 分けてここに置く。コンテナ一覧の引数は registry から `container_args` で受け取る
--- (registry を require し返すと循環参照になる)。
local cli = require("docker.adapters.docker.cli")
local compose = require("docker.adapters.docker.compose")
local services = require("docker.resources.services")

local M = {}

---@class docker.ServiceLoadContext
---@field cwd string           ビューを開いた時点の作業ディレクトリ
---@field container_args string[] コンテナ一覧を取る docker 引数

--- サービス一覧を取得する。
---@param ctx docker.ServiceLoadContext
---@param on_done fun(result: docker.Result)
function M.load(ctx, on_done)
  compose.resolve_project(ctx.cwd, function(resolved)
    if not resolved.ok then
      on_done(resolved)
      return
    end
    cli.run(ctx.container_args, function(containers)
      if not containers.ok then
        on_done(containers)
        return
      end
      on_done({
        ok = true,
        data = services.assemble(resolved.data, containers.data),
        error = nil,
        code = 0,
        project = resolved.data,
      })
    end, { parse = "ndjson" })
  end)
end

return M
