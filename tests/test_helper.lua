-- Test helper utilities
local M = {}

-- Simple assertion framework
function M.assert_equal(actual, expected, message)
	if actual ~= expected then
		local msg = message or string.format("Expected %s, got %s", vim.inspect(expected), vim.inspect(actual))
		error(msg)
	end
end

function M.assert_true(condition, message)
	if not condition then
		error(message or "Expected true, got false")
	end
end

function M.assert_false(condition, message)
	if condition then
		error(message or "Expected false, got true")
	end
end

function M.assert_nil(value, message)
	if value ~= nil then
		error(message or "Expected nil, got " .. vim.inspect(value))
	end
end

function M.assert_not_nil(value, message)
	if value == nil then
		error(message or "Expected non-nil value")
	end
end

-- Test execution helper
function M.describe(description, tests)
	print("  " .. description)

	for test_name, test_func in pairs(tests) do
		local ok, err = pcall(test_func)
		if ok then
			print("    ✓ " .. test_name)
		else
			print("    ✗ " .. test_name .. ": " .. err)
			error("Test failed: " .. test_name)
		end
	end
end

-- Mock Docker API responses
M.mock_containers = {
	{
		Id = "abc123",
		Names = { "/nginx-app" },
		Image = "nginx:latest",
		State = "running",
		Status = "Up 2 hours",
		Ports = {
			{
				PublicPort = 8080,
				PrivatePort = 80,
				Type = "tcp",
			},
		},
		Created = 1672531200,
	},
	{
		Id = "def456",
		Names = { "/postgres-db" },
		Image = "postgres:14",
		State = "exited",
		Status = "Exited (0) 1 hour ago",
		Ports = {},
		Created = 1672527600,
	},
}

M.mock_images = {
	{
		Id = "sha256:abc123",
		RepoTags = { "nginx:latest" },
		Size = 157000000,
		Created = 1672531200,
	},
	{
		Id = "sha256:def456",
		RepoTags = { "postgres:14" },
		Size = 314000000,
		Created = 1672527600,
	},
}

return M
