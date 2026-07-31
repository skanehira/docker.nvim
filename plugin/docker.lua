-- Entry point of docker.nvim.
-- This is loaded at Neovim startup, so no heavy module is required here.
-- In environments that do not meet the required version, neither the command nor the
-- keymaps are registered.

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

-- Let users bind these to any key they like.
for _, name in ipairs({ "containers", "images", "volumes", "networks", "services" }) do
  vim.keymap.set("n", ("<Plug>(docker-%s)"):format(name), function()
    require("docker").open(name)
  end, { desc = ("docker.nvim: %s を開く"):format(name) })
end
