.PHONY: test test-file test-e2e plugin-check spec-layout-check lint format format-check typecheck check help

MINIMAL_INIT := tests/minimal_init.lua
LUA_DIRS := lua/ plugin/ tests/

export MINIMAL_INIT

# Unit and integration tests. Runs every *_spec.lua placed next to the implementation.
# tests/e2e/ is excluded because it requires docker (test-e2e covers it).
# run-busted.sh tells "nothing ran at all" apart from a success.
test: spec-layout-check
	@./scripts/run-busted.sh lua/

# Run a single file. The goal verification steps name the file explicitly, so exit non-zero
# on all of the following to keep the check from being hollow:
#   FILE not given / file missing / not a *_spec.lua / no test ran at all
test-file:
	@test -n "$(FILE)" || { echo "FILE is required: make test-file FILE=path/to/foo_spec.lua" >&2; exit 1; }
	@test -f "$(FILE)" || { echo "test file not found: $(FILE)" >&2; exit 1; }
	@case "$(FILE)" in \
		*_spec.lua) ;; \
		*) echo "not a spec file (must end with _spec.lua): $(FILE)" >&2; exit 1 ;; \
	esac
	@./scripts/run-busted.sh "$(FILE)"

# The end-to-end scenarios of G_E2E. Requires docker.
test-e2e:
	@./scripts/e2e.sh

# `make test` only scans lua/, so a spec outside it ends up "present but never run".
# Fail instead of staying silent.
spec-layout-check:
	@stray=$$(find . -type f -name '*_spec.lua' \
		-not -path './.git/*' -not -path './lua/*' -not -path './tests/e2e/*' -not -path './docs/*'); \
		if [ -n "$$stray" ]; then \
			echo "spec files outside lua/ are never run by 'make test':" >&2; \
			printf '%s\n' "$$stray" >&2; \
			exit 1; \
		fi

plugin-check:
	@./scripts/plugin-check.sh

lint:
	@luacheck $(LUA_DIRS) --config .luacheckrc

format:
	@stylua $(LUA_DIRS) --config-path stylua.toml

format-check:
	@stylua $(LUA_DIRS) --config-path stylua.toml --check

typecheck:
	@./scripts/typecheck.sh

check: lint format-check typecheck plugin-check spec-layout-check test

help:
	@echo "test              - run every unit and integration test"
	@echo "test-file         - run a single file (FILE=path/to/foo_spec.lua)"
	@echo "test-e2e          - the end-to-end scenarios of G_E2E (requires docker)"
	@echo "plugin-check      - check that plugin/*.lua is sourced without load errors"
	@echo "spec-layout-check - check that no spec sits outside the run targets"
	@echo "lint              - luacheck"
	@echo "format            - format with stylua"
	@echo "format-check      - check for stylua diffs"
	@echo "typecheck         - lua-language-server"
	@echo "check             - run all of the static checks above plus the tests"
