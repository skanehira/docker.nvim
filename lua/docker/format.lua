--- Building docker's output template, and parsing NDJSON.
---
--- Listing uses a template that lines up a `{{json ...}}` per field. One record stays on one
--- line even when a value contains a comma, a newline, a quote or a backslash.
--- The `Labels` field must never be split to extract labels (label values themselves contain
--- commas, and a forged label planted in a value would make us pick up the wrong one). Labels
--- are fetched by naming the key with `.Label`.
local M = {}

---@class docker.FieldSpec
---@field key string   Key name in the output JSON
---@field expr string  Go template expression (e.g. ".ID")

--- Build a Go template expression that extracts a label by naming its key.
---@param name string Label name (e.g. "com.docker.compose.project")
---@return string
function M.label_expr(name)
  return string.format('(.Label "%s")', name)
end

--- Build the template string passed to `--format` from the field definitions.
---@param fields docker.FieldSpec[]
---@return string
function M.template(fields)
  local parts = {}
  for _, field in ipairs(fields) do
    table.insert(parts, string.format('"%s":{{json %s}}', field.key, field.expr))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

--- Parse NDJSON one line at a time.
--- Empty lines and whitespace-only lines are not counted as skipped (docker appends a
--- trailing newline).
--- Lines that cannot be parsed are skipped, and their count is returned.
---@param text string
---@return table[] items
---@return integer skipped Number of lines skipped because they could not be parsed
function M.parse_ndjson(text)
  local items = {}
  local skipped = 0

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("%S") then
      local ok, decoded = pcall(vim.json.decode, line)
      if ok and type(decoded) == "table" then
        table.insert(items, decoded)
      else
        skipped = skipped + 1
      end
    end
  end

  return items, skipped
end

return M
