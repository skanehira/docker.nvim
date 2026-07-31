local ports = require("docker.resources.ports")

describe("docker.resources.ports", function()
  describe("published", function()
    it("returns nothing when there are no published ports", function()
      assert.are.same({}, ports.published(""))
    end)

    it("builds a URL from a single published port", function()
      assert.are.same({ "http://localhost:8080" }, ports.published("0.0.0.0:8080->80/tcp"))
    end)

    it("reads an unspecified listening address as localhost", function()
      -- 0.0.0.0 and :: cannot be connected to, so make it a destination a browser can open.
      assert.are.same({ "http://localhost:8080" }, ports.published(":::8080->80/tcp"))
    end)

    it("uses the address as is when the port is bound to a specific address", function()
      assert.are.same({ "http://127.0.0.1:9000" }, ports.published("127.0.0.1:9000->80/tcp"))
    end)

    it("returns multiple published ports without duplicates", function()
      -- docker sometimes emits both IPv4 and IPv6 as separate entries.
      local actual = ports.published("0.0.0.0:8080->80/tcp, :::8080->80/tcp, 0.0.0.0:9090->90/tcp")

      assert.are.same({ "http://localhost:8080", "http://localhost:9090" }, actual)
    end)

    it("excludes ports that are not published", function()
      -- A port that is not exposed on the host cannot be opened from a browser.
      assert.are.same({}, ports.published("80/tcp, 443/tcp"))
    end)

    it("returns only the published ones when published and unpublished ports are mixed", function()
      assert.are.same({ "http://localhost:8080" }, ports.published("80/tcp, 0.0.0.0:8080->80/tcp"))
    end)

    it("does not consider udp ports", function()
      -- They cannot be opened in a browser.
      assert.are.same({}, ports.published("0.0.0.0:5353->53/udp"))
    end)

    it("returns the URLs in ascending order of port number", function()
      local actual = ports.published("0.0.0.0:9090->90/tcp, 0.0.0.0:8080->80/tcp")

      assert.are.same({ "http://localhost:8080", "http://localhost:9090" }, actual)
    end)

    it("also considers ports published as a range", function()
      -- `docker run -p 8000-8002:8000-8002` shows up in this form. Do not drop it entirely.
      assert.are.same({ "http://localhost:8000" }, ports.published("0.0.0.0:8000-8002->8000-8002/tcp"))
    end)

    it("returns nothing when the value is nil", function()
      assert.are.same({}, ports.published(nil))
    end)
  end)
end)
