local ports = require("docker.resources.ports")

describe("docker.resources.ports", function()
  describe("published", function()
    it("公開ポートが無いとき空を返す", function()
      assert.are.same({}, ports.published(""))
    end)

    it("公開ポート1件からURLを組み立てる", function()
      assert.are.same({ "http://localhost:8080" }, ports.published("0.0.0.0:8080->80/tcp"))
    end)

    it("待ち受けアドレスが不定のときlocalhostに読み替える", function()
      -- 0.0.0.0 や :: へは接続できないので、ブラウザで開ける宛先にする。
      assert.are.same({ "http://localhost:8080" }, ports.published(":::8080->80/tcp"))
    end)

    it("特定のアドレスに束縛されているときはそのアドレスを使う", function()
      assert.are.same({ "http://127.0.0.1:9000" }, ports.published("127.0.0.1:9000->80/tcp"))
    end)

    it("複数の公開ポートを重複なく返す", function()
      -- docker は IPv4 と IPv6 の両方を別項目で出すことがある。
      local actual = ports.published("0.0.0.0:8080->80/tcp, :::8080->80/tcp, 0.0.0.0:9090->90/tcp")

      assert.are.same({ "http://localhost:8080", "http://localhost:9090" }, actual)
    end)

    it("公開されていないポートは除く", function()
      -- ホスト側へ出ていないポートはブラウザから開けない。
      assert.are.same({}, ports.published("80/tcp, 443/tcp"))
    end)

    it("公開ポートと非公開ポートが混ざっていても公開分だけ返す", function()
      assert.are.same({ "http://localhost:8080" }, ports.published("80/tcp, 0.0.0.0:8080->80/tcp"))
    end)

    it("udp のポートは対象にしない", function()
      -- ブラウザで開けない。
      assert.are.same({}, ports.published("0.0.0.0:5353->53/udp"))
    end)

    it("ポート番号の昇順で返す", function()
      local actual = ports.published("0.0.0.0:9090->90/tcp, 0.0.0.0:8080->80/tcp")

      assert.are.same({ "http://localhost:8080", "http://localhost:9090" }, actual)
    end)

    it("範囲で公開されたポートも対象にする", function()
      -- `docker run -p 8000-8002:8000-8002` はこの形で出る。丸ごと落とさない。
      assert.are.same({ "http://localhost:8000" }, ports.published("0.0.0.0:8000-8002->8000-8002/tcp"))
    end)

    it("値がnilでも空を返す", function()
      assert.are.same({}, ports.published(nil))
    end)
  end)
end)
