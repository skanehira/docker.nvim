local fields = require("docker.resources.fields")

--- 一覧取得で得られるコンテナの生データ。指定した項目だけ上書きする。
---@param overrides table|nil
---@return table
local function container(overrides)
  return vim.tbl_extend("force", {
    id = "abc123",
    name = "web",
    image = "alpine",
    state = "running",
    status = "Up 5 days",
    ports = "",
    command = '"sleep 600"',
    created_at = "2026-07-29 10:00:00 +0900 JST",
    compose_project = "",
    compose_service = "",
    compose_oneoff = "",
  }, overrides or {})
end

describe("docker.resources.fields", function()
  describe("is_compose", function()
    it("プロジェクト名とサービス名が揃っているときcompose由来と判定する", function()
      local item = container({ compose_project = "shop", compose_service = "web", compose_oneoff = "False" })

      assert.is_true(fields.is_compose(item))
    end)

    it("ラベルが無いコンテナはcompose由来と判定しない", function()
      assert.is_false(fields.is_compose(container()))
    end)

    it("プロジェクト名だけありサービス名が空ならcompose由来と判定しない", function()
      assert.is_false(fields.is_compose(container({ compose_project = "shop" })))
    end)

    it("サービス名だけありプロジェクト名が空ならcompose由来と判定しない", function()
      assert.is_false(fields.is_compose(container({ compose_service = "web" })))
    end)
  end)

  describe("is_oneoff", function()
    it("oneoffラベルがTrueのとき単発コンテナと判定する", function()
      local item = container({ compose_project = "shop", compose_service = "web", compose_oneoff = "True" })

      assert.is_true(fields.is_oneoff(item))
    end)

    it("oneoffラベルがFalseのとき単発コンテナと判定しない", function()
      assert.is_false(fields.is_oneoff(container({ compose_oneoff = "False" })))
    end)

    it("oneoffラベルが空のとき単発コンテナと判定しない", function()
      assert.is_false(fields.is_oneoff(container()))
    end)
  end)

  describe("service_of", function()
    it("compose由来の通常コンテナはプロジェクトとサービスの組を返す", function()
      local item = container({ compose_project = "shop", compose_service = "web", compose_oneoff = "False" })

      assert.are.same({ project = "shop", service = "web" }, fields.service_of(item))
    end)

    it("単発コンテナはサービスに紐付けない", function()
      -- BR-006: `docker compose run` が作る単発コンテナはサービスの実体ではない。
      local item = container({ compose_project = "shop", compose_service = "web", compose_oneoff = "True" })

      assert.is_nil(fields.service_of(item))
    end)

    it("compose由来でないコンテナはサービスに紐付けない", function()
      assert.is_nil(fields.service_of(container()))
    end)
  end)

  describe("ports", function()
    it("公開ポートが無いとき空文字列を返す", function()
      assert.are.equal("", fields.ports(container()))
    end)

    it("公開ポートの文字列をそのまま返す", function()
      local item = container({ ports = "0.0.0.0:8080->80/tcp" })

      assert.are.equal("0.0.0.0:8080->80/tcp", fields.ports(item))
    end)
  end)

  describe("state", function()
    it("状態の文字列をそのまま返す", function()
      assert.are.equal("running", fields.state(container()))
    end)

    it("状態が欠けているとき空文字列を返す", function()
      local item = container()
      item.state = nil

      assert.are.equal("", fields.state(item))
    end)
  end)
end)
