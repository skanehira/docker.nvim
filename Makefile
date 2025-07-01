.PHONY: test lint format clean help

# Default target
help:
	@echo "Available targets:"
	@echo "  test     - Run all tests"
	@echo "  lint     - Run linter (stylua)"
	@echo "  format   - Format code (stylua)"
	@echo "  clean    - Clean temporary files"
	@echo "  help     - Show this help message"

# Run tests using TDD approach
test:
	@echo "Running docker.nvim test suite..."
	@nvim -l tests/run_tests.lua

# Lint Lua code with stylua (if available)
lint:
	@if command -v stylua >/dev/null 2>&1; then \
		echo "Running stylua check..."; \
		stylua --check lua/ tests/ plugin/; \
	else \
		echo "stylua not found. Install with: cargo install stylua"; \
		exit 1; \
	fi

# Format Lua code with stylua
format:
	@if command -v stylua >/dev/null 2>&1; then \
		echo "Formatting code with stylua..."; \
		stylua lua/ tests/ plugin/; \
	else \
		echo "stylua not found. Install with: cargo install stylua"; \
		exit 1; \
	fi

# Clean temporary files
clean:
	@echo "Cleaning temporary files..."
	@find . -name "*.tmp" -delete 2>/dev/null || true
	@find . -name "*.log" -delete 2>/dev/null || true

# Development workflow - run tests continuously
watch:
	@echo "Watching for changes and running tests..."
	@while true; do \
		make test; \
		echo "Waiting for changes... (Ctrl+C to stop)"; \
		sleep 2; \
	done