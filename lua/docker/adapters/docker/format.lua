--- docker の出力テンプレートの組み立てと、NDJSON の解析。
---
--- 一覧取得ではフィールドごとに `{{json ...}}` を並べたテンプレートを使う。
--- 値にカンマ・改行・引用符・バックスラッシュが含まれても 1 レコード 1 行が保たれる。
--- `Labels` フィールドを分割してラベルを取り出してはならない (ラベル値自体がカンマを
--- 含むうえ、値に偽のラベルを仕込まれると誤った値を掴む)。ラベルは `.Label` による
--- キー名指しで取得する。
local M = {}

---@class docker.FieldSpec
---@field key string   出力 JSON のキー名
---@field expr string  Go テンプレートの式 (例: ".ID")

--- ラベルをキー名指しで取り出す Go テンプレート式を作る。
---@param name string ラベル名 (例: "com.docker.compose.project")
---@return string
function M.label_expr(name)
  return string.format('(.Label "%s")', name)
end

--- フィールド定義から `--format` に渡すテンプレート文字列を作る。
---@param fields docker.FieldSpec[]
---@return string
function M.template(fields)
  local parts = {}
  for _, field in ipairs(fields) do
    table.insert(parts, string.format('"%s":{{json %s}}', field.key, field.expr))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

--- NDJSON を 1 行ずつ解析する。
--- 空行と空白のみの行は読み飛ばし件数に数えない (docker が末尾に改行を付けるため)。
--- 解析できない行は読み飛ばし、その件数を返す。
---@param text string
---@return table[] items
---@return integer skipped 解析できずに読み飛ばした行数
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
