-- docker.nvim - Neovim Docker plugin
-- Main plugin entry point

if vim.g.loaded_docker_nvim then
	return
end
vim.g.loaded_docker_nvim = 1

-- Commands
vim.api.nvim_create_user_command("DockerContainers", function()
	require("docker").show_containers()
end, {
	desc = "Show Docker containers in floating window",
})

vim.api.nvim_create_user_command("DockerImages", function()
	require("docker").show_images()
end, {
	desc = "Show Docker images in floating window",
})

-- Default keymaps (users can override these)
vim.keymap.set("n", "<leader>dc", "<cmd>DockerContainers<cr>", {
	desc = "Docker: Show containers",
})

vim.keymap.set("n", "<leader>di", "<cmd>DockerImages<cr>", {
	desc = "Docker: Show images",
})
