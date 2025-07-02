#!/usr/bin/env nvim -l

-- Simple test runner for docker.nvim
-- Usage: nvim -l tests/run_tests.lua

local function run_test_file(file)
	print("Running tests in: " .. file)
	local ok, result = pcall(dofile, file)
	if not ok then
		print("ERROR: " .. result)
		return false
	end
	return true
end

local function find_test_files()
	local tests = {}
	local handle = io.popen('find tests -name "*_spec.lua" 2>/dev/null')
	if handle then
		for line in handle:lines() do
			table.insert(tests, line)
		end
		handle:close()
	end
	return tests
end

-- Main test runner
local function main()
	print("=== docker.nvim Test Suite ===")

	-- Add project to Lua path
	local project_root = vim.fn.getcwd()
	package.path = project_root .. "/lua/?.lua;" .. package.path

	local test_files = find_test_files()
	local passed = 0
	local failed = 0

	for _, file in ipairs(test_files) do
		if run_test_file(file) then
			passed = passed + 1
		else
			failed = failed + 1
		end
	end

	print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))

	if failed > 0 then
		os.exit(1)
	end
end

main()
