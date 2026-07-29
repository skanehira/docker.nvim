-- vim: ft=lua
std = "luajit"
cache = true

globals = {
  "vim",
}

read_globals = {
  -- plenary/busted のテストグローバル
  "describe",
  "it",
  "before_each",
  "after_each",
  "assert",
}

ignore = {
  "631", -- max_line_length: 整形は stylua が担当する
}

exclude_files = {
  ".luarocks",
  "lua_modules",
}
