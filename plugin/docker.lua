-- docker.nvim のエントリポイント。
-- Neovim 起動時に読み込まれるため、ここでは重いモジュールを require しない。
-- 要求バージョンを満たさない環境ではコマンドもキーマップも登録しない。

if vim.g.loaded_docker_nvim then
  return
end
vim.g.loaded_docker_nvim = true

if not require("docker.version").supported() then
  return
end

vim.api.nvim_create_user_command("Docker", function(opts)
  require("docker").open(opts.args)
end, {
  nargs = "?",
  desc = "docker.nvim: リソース一覧を開く",
  complete = function(arg_lead)
    local matched = {}
    for _, name in ipairs(require("docker.resources.registry").subcommands()) do
      if name:sub(1, #arg_lead) == arg_lead then
        table.insert(matched, name)
      end
    end
    return matched
  end,
})

-- 利用者が任意のキーへ割り当てられるようにする。
for _, name in ipairs({ "containers", "images", "volumes", "networks", "services" }) do
  vim.keymap.set("n", ("<Plug>(docker-%s)"):format(name), function()
    require("docker").open(name)
  end, { desc = ("docker.nvim: %s を開く"):format(name) })
end
