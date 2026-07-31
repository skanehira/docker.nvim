local format = require("docker.format")

--- The fixtures are real docker output collected during the PoC (tests/fixtures/).
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
    it("turns a label name into a Go template expression that names the key", function()
      assert.are.equal('(.Label "com.docker.compose.project")', format.label_expr("com.docker.compose.project"))
    end)
  end)

  describe("template", function()
    it("produces a JSON object with one key-expression pair for a single field", function()
      assert.are.equal('{"id":{{json .ID}}}', format.template({ { key = "id", expr = ".ID" } }))
    end)

    it("joins multiple fields with commas in their definition order", function()
      local actual = format.template({
        { key = "id", expr = ".ID" },
        { key = "name", expr = ".Names" },
        { key = "state", expr = ".State" },
      })
      assert.are.equal('{"id":{{json .ID}},"name":{{json .Names}},"state":{{json .State}}}', actual)
    end)

    it("expands a label expression as the argument of the json function", function()
      local actual = format.template({
        { key = "compose_project", expr = format.label_expr("com.docker.compose.project") },
      })
      assert.are.equal('{"compose_project":{{json (.Label "com.docker.compose.project")}}}', actual)
    end)
  end)

  describe("parse_ndjson", function()
    it("returns one table and zero skipped lines for a single line of JSON", function()
      local items, skipped = format.parse_ndjson('{"id":"abc","name":"web"}')

      assert.are.same({ { id = "abc", name = "web" } }, items)
      assert.are.equal(0, skipped)
    end)

    it("returns the tables in input order for multiple lines of JSON", function()
      local items, skipped = format.parse_ndjson('{"id":"a"}\n{"id":"b"}\n{"id":"c"}')

      assert.are.same({ { id = "a" }, { id = "b" }, { id = "c" } }, items)
      assert.are.equal(0, skipped)
    end)

    it("returns an empty table and zero skipped lines for an empty string", function()
      local items, skipped = format.parse_ndjson("")

      assert.are.same({}, items)
      assert.are.equal(0, skipped)
    end)

    it("does not count empty and whitespace-only lines as skipped", function()
      local items, skipped = format.parse_ndjson('{"id":"a"}\n\n   \n{"id":"b"}\n')

      assert.are.same({ { id = "a" }, { id = "b" } }, items)
      assert.are.equal(0, skipped)
    end)

    it("skips the lines that cannot be parsed and returns their count", function()
      local items, skipped = format.parse_ndjson('{"id":"a"}\nnot json\n{"id":\n{"id":"b"}')

      assert.are.same({ { id = "a" }, { id = "b" } }, items)
      assert.are.equal(2, skipped)
    end)

    it("skips JSON lines that are not objects", function()
      -- Lines holding a number, a string or a boolean cannot be treated as a record.
      local items, skipped = format.parse_ndjson('{"id":"a"}\n123\n"text"\ntrue\n')

      assert.are.same({ { id = "a" } }, items)
      assert.are.equal(3, skipped)
    end)

    it("does not drop the last line when there is no trailing newline", function()
      local items, skipped = format.parse_ndjson('{"id":"a"}\n{"id":"b"}')

      assert.are.same({ { id = "a" }, { id = "b" } }, items)
      assert.are.equal(0, skipped)
    end)

    it("parses a value containing commas, quotes and backslashes as a single record", function()
      local line = '{"name":"x","labels":"a=1,b=2","quoted":"he said \\"hi\\"","path":"C:\\\\tmp"}'
      local items, skipped = format.parse_ndjson(line)

      assert.are.same({
        { name = "x", labels = "a=1,b=2", quoted = 'he said "hi"', path = "C:\\tmp" },
      }, items)
      assert.are.equal(0, skipped)
    end)

    it("extracts the compose columns of every container from real docker output", function()
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

    it("misreads a spoofed compose_project label with naive Labels splitting but not with key naming", function()
      -- Cross-checks real data collected for the same container (matching id) with two different
      -- --format options. A regression test that retains why Labels must not be split.
      -- Regressing to the splitting approach would pick up the SPOOFED value an attacker planted.
      local spoofed = vim.json.decode(read_fixture("container_labels_spoofed.json"))

      -- (1) Naively splitting the Labels of `--format json` on commas picks up the forged value
      local naive
      for _, pair in ipairs(vim.split(spoofed.Labels, ",", { plain = true })) do
        local key, value = pair:match("^([^=]+)=(.*)$")
        if key == "com.docker.compose.project" then
          naive = value
        end
      end
      assert.are.equal("SPOOFED", naive)

      -- (2) The same container collected by naming the key with `.Label` stays an empty string
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
    end)

    it("extracts only the valid lines from real data with broken lines and returns the skipped count", function()
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
    end)
  end)
end)
