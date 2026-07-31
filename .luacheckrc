-- vim: ft=lua
std = "luajit"
cache = true

globals = {
  "vim",
}

read_globals = {
  -- Test globals of plenary/busted
  "describe",
  "it",
  "before_each",
  "after_each",
  "assert",
}

ignore = {
  "631", -- max_line_length: formatting is stylua's job
}

exclude_files = {
  ".luarocks",
  "lua_modules",
}
