.PHONY: test test-file test-e2e plugin-check spec-layout-check lint format format-check typecheck check help

MINIMAL_INIT := tests/minimal_init.lua
LUA_DIRS := lua/ plugin/ tests/

export MINIMAL_INIT

# 単体・結合テスト。実装と同じディレクトリに置いた *_spec.lua を全実行する。
# tests/e2e/ は docker を必要とするため含めない (test-e2e が担当)。
# run-busted.sh が「1 件も実行されていない」を成功と区別する。
test: spec-layout-check
	@./scripts/run-busted.sh lua/

# 単一ファイルの実行。ゴールの検証手順がファイル名を名指しするため、検証が空虚に
# ならないよう次をすべて非 0 で終了させる:
#   FILE 未指定 / ファイル不在 / *_spec.lua でない / テストが 1 件も実行されなかった
test-file:
	@test -n "$(FILE)" || { echo "FILE is required: make test-file FILE=path/to/foo_spec.lua" >&2; exit 1; }
	@test -f "$(FILE)" || { echo "test file not found: $(FILE)" >&2; exit 1; }
	@case "$(FILE)" in \
		*_spec.lua) ;; \
		*) echo "not a spec file (must end with _spec.lua): $(FILE)" >&2; exit 1 ;; \
	esac
	@./scripts/run-busted.sh "$(FILE)"

# G_E2E の通しシナリオ。docker が必要。
test-e2e:
	@./scripts/e2e.sh

# `make test` が走査するのは lua/ だけなので、そこから外れた spec は
# 「存在するが一度も実行されない」状態になる。沈黙させず落とす。
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
	@echo "test              - 単体・結合テストを全実行"
	@echo "test-file         - 単一ファイルを実行 (FILE=path/to/foo_spec.lua)"
	@echo "test-e2e          - G_E2E の通しシナリオ (docker が必要)"
	@echo "plugin-check      - plugin/*.lua が読み込みエラーなく source されるか確認"
	@echo "spec-layout-check - 実行対象から外れた場所に spec が無いか確認"
	@echo "lint              - luacheck"
	@echo "format            - stylua で整形"
	@echo "format-check      - stylua の差分チェック"
	@echo "typecheck         - lua-language-server"
	@echo "check             - 上記の静的検査とテストをまとめて実行"
