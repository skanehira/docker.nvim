local format = require("docker.format")

--- フィクスチャは PoC で採取した実際の docker 出力 (tests/fixtures/)。
---@param name string
---@return string
local function read_fixture(name)
  local path = "tests/fixtures/" .. name
  local fd = assert(io.open(path, "r"), "fixture not found: " .. path)
  local content = fd:read("*a")
  fd:close()
  return content
end

describe("docker.format", function()
  describe("label_expr", function()
    it("ラベル名を渡すとキー名指しのGoテンプレート式になる", function()
      assert.are.equal('(.Label "com.docker.compose.project")', format.label_expr("com.docker.compose.project"))
    end)
  end)

  describe("template", function()
    it("フィールドが1件のときキーと式が1組のJSONオブジェクトになる", function()
      assert.are.equal('{"id":{{json .ID}}}', format.template({ { key = "id", expr = ".ID" } }))
    end)

    it("フィールドが複数のとき定義順にカンマで連結される", function()
      local actual = format.template({
        { key = "id", expr = ".ID" },
        { key = "name", expr = ".Names" },
        { key = "state", expr = ".State" },
      })
      assert.are.equal('{"id":{{json .ID}},"name":{{json .Names}},"state":{{json .State}}}', actual)
    end)

    it("ラベル式を渡すとjson関数の引数として展開される", function()
      local actual = format.template({
        { key = "compose_project", expr = format.label_expr("com.docker.compose.project") },
      })
      assert.are.equal('{"compose_project":{{json (.Label "com.docker.compose.project")}}}', actual)
    end)
  end)

  describe("parse_ndjson", function()
    it("1行のJSONを渡すと1件のテーブルと読み飛ばし0件を返す", function()
      local items, skipped = format.parse_ndjson('{"id":"abc","name":"web"}')

      assert.are.same({ { id = "abc", name = "web" } }, items)
      assert.are.equal(0, skipped)
    end)

    it("複数行のJSONを渡すと入力順に並んだテーブルを返す", function()
      local items, skipped = format.parse_ndjson('{"id":"a"}\n{"id":"b"}\n{"id":"c"}')

      assert.are.same({ { id = "a" }, { id = "b" }, { id = "c" } }, items)
      assert.are.equal(0, skipped)
    end)

    it("空文字列を渡すと空のテーブルと読み飛ばし0件を返す", function()
      local items, skipped = format.parse_ndjson("")

      assert.are.same({}, items)
      assert.are.equal(0, skipped)
    end)

    it("空行と空白のみの行は読み飛ばし件数に数えない", function()
      local items, skipped = format.parse_ndjson('{"id":"a"}\n\n   \n{"id":"b"}\n')

      assert.are.same({ { id = "a" }, { id = "b" } }, items)
      assert.are.equal(0, skipped)
    end)

    it("解析できない行は読み飛ばしその件数を返す", function()
      local items, skipped = format.parse_ndjson('{"id":"a"}\nnot json\n{"id":\n{"id":"b"}')

      assert.are.same({ { id = "a" }, { id = "b" } }, items)
      assert.are.equal(2, skipped)
    end)

    it("オブジェクトでないJSONの行は読み飛ばす", function()
      -- 数値・文字列・真偽値の行はレコードとして扱えない。
      local items, skipped = format.parse_ndjson('{"id":"a"}\n123\n"text"\ntrue\n')

      assert.are.same({ { id = "a" } }, items)
      assert.are.equal(3, skipped)
    end)

    it("末尾に改行が無くても最後の行を取りこぼさない", function()
      local items, skipped = format.parse_ndjson('{"id":"a"}\n{"id":"b"}')

      assert.are.same({ { id = "a" }, { id = "b" } }, items)
      assert.are.equal(0, skipped)
    end)

    it(
      "値にカンマ・引用符・バックスラッシュを含んでも1レコードとして解析できる",
      function()
        local line = '{"name":"x","labels":"a=1,b=2","quoted":"he said \\"hi\\"","path":"C:\\\\tmp"}'
        local items, skipped = format.parse_ndjson(line)

        assert.are.same({
          { name = "x", labels = "a=1,b=2", quoted = 'he said "hi"', path = "C:\\tmp" },
        }, items)
        assert.are.equal(0, skipped)
      end
    )

    it("実際のdocker出力から全コンテナのcompose列を取り出せる", function()
      local items, skipped = format.parse_ndjson(read_fixture("containers.ndjson"))

      assert.are.equal(0, skipped)
      local actual = {}
      for _, item in ipairs(items) do
        table.insert(actual, {
          name = item.name,
          state = item.state,
          compose_project = item.compose_project,
          compose_service = item.compose_service,
          compose_oneoff = item.compose_oneoff,
        })
      end
      assert.are.same({
        {
          name = "dockernvim-fixture-proj-worker-run-7b5ee0a0d225",
          state = "running",
          compose_project = "dockernvim-fixture-proj",
          compose_service = "worker",
          compose_oneoff = "True",
        },
        {
          name = "dockernvim-fixture-proj-worker-1",
          state = "exited",
          compose_project = "dockernvim-fixture-proj",
          compose_service = "worker",
          compose_oneoff = "False",
        },
        {
          name = "dockernvim-fixture-proj-web-1",
          state = "running",
          compose_project = "dockernvim-fixture-proj",
          compose_service = "web",
          compose_oneoff = "False",
        },
        {
          name = "dockernvim-fixture-evil",
          state = "created",
          compose_project = "",
          compose_service = "",
          compose_oneoff = "",
        },
        {
          name = "dockernvim-fixture-plain",
          state = "running",
          compose_project = "",
          compose_service = "",
          compose_oneoff = "",
        },
      }, actual)
    end)

    it(
      "ラベル値に偽のcompose_projectを仕込んだコンテナを素朴なLabels分割は誤読しキー名指しは誤読しない",
      function()
        -- 同一のコンテナ (id が一致する) を 2 通りの --format で採取した実データを突き合わせ、
        -- 「なぜ Labels を分割してはならないか」を retain する回帰テスト。
        -- 分割方式に退行させると、攻撃者が仕込んだ SPOOFED を掴んでしまう。
        local spoofed = vim.json.decode(read_fixture("container_labels_spoofed.json"))

        -- (1) `--format json` の Labels を素朴にカンマ分割すると偽の値を掴む
        local naive
        for _, pair in ipairs(vim.split(spoofed.Labels, ",", { plain = true })) do
          local key, value = pair:match("^([^=]+)=(.*)$")
          if key == "com.docker.compose.project" then
            naive = value
          end
        end
        assert.are.equal("SPOOFED", naive)

        -- (2) `.Label` によるキー名指しで採取した同じコンテナは空文字列のまま
        local items = format.parse_ndjson(read_fixture("containers.ndjson"))
        local evil
        for _, item in ipairs(items) do
          if item.id == spoofed.ID then
            evil = item
          end
        end
        evil = assert(evil, "containers.ndjson must contain the same container id as the spoofed fixture")

        assert.are.equal("dockernvim-fixture-evil", evil.name)
        assert.are.equal("", evil.compose_project)
        assert.are.equal("", evil.compose_service)
      end
    )

    it(
      "壊れた行を含む実データでも有効な行だけを取り出し読み飛ばし件数を返す",
      function()
        local items, skipped = format.parse_ndjson(read_fixture("containers_malformed.ndjson"))

        local names = {}
        for _, item in ipairs(items) do
          table.insert(names, item.name)
        end
        assert.are.same({
          "dockernvim-fixture-proj-worker-run-7b5ee0a0d225",
          "dockernvim-fixture-proj-worker-1",
          "dockernvim-fixture-plain",
        }, names)
        assert.are.equal(2, skipped)
      end
    )
  end)
end)
