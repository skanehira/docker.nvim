#!/usr/bin/env bash
#
# plenary の busted ハーネスを起動し、「テストが実際に実行されたこと」まで検証する。
#
# 終了コードだけを信じると、次のいずれも「成功」に見えてしまう:
#   - spec ファイルはあるが it が 1 件も無い
#   - テストが pending になっている (plenary は pending を Success の件数にも数えるため、
#     実行後の出力だけでは全件 pending でも成功と区別できない)
#   - 走査対象に spec ファイルが 1 件も無い (削除・改名・別ディレクトリへの移動)
# ゴールの検証手順 (DESIGN_DETAIL_APP.md 9 章) はすべてこの終了コードに依存するため、
# 「1 件も走っていない」を成功と区別できないと受入検証が空虚になる。
#
# このスクリプトが保証しないこと (誤解を避けるため明記する):
#   - spec が「対応する実装を本当に検証しているか」は判定できない。
#     `assert.are.same(1, 1)` だけの spec でも通る。これは review-tdd と
#     review-adversarial の責務であり、シェルの終了コードでは代替できない
#   - spec 内から意図的に os.exit を呼ぶ等、ハーネスを騙す目的のコードは
#     静的検査で弾ける範囲までしか防げない (下の check_spec_sanity)
#   - 一部の spec だけが削除された場合は検出できない (spec 数とサマリ数が同時に減るため)
#
# 使い方: run-busted.sh <ディレクトリ | *_spec.lua>
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

TARGET=${1:?usage: run-busted.sh <dir-or-spec-file>}
MINIMAL_INIT=${MINIMAL_INIT:-$REPO_ROOT/tests/minimal_init.lua}

# minimal_init を読めないと nvim は -u を無視して起動し、PlenaryBusted* が
# 未定義コマンドのままヘッドレス nvim が終了しなくなる (無応答 = CI が検知できない)。
# minimal_init 自身のガードはそれが読み込まれた場合にしか働かないので、ここで先に見る。
if [ ! -f "$MINIMAL_INIT" ]; then
  echo "run-busted: minimal init not found: $MINIMAL_INIT" >&2
  exit 1
fi

if [ ! -e "$TARGET" ]; then
  echo "run-busted: target not found: $TARGET" >&2
  exit 1
fi

for tool in nvim perl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "run-busted: required tool not found: $tool" >&2; exit 1; }
done

# 対象に含まれる spec ファイル。plenary は spec ファイル 1 つにつき
# サマリブロックを 1 つ出力するので、この数が期待値になる。
if [ -d "$TARGET" ]; then
  specs=$(find "$TARGET" -type f -name '*_spec.lua' | sort)
else
  specs=$TARGET
fi
spec_count=$(printf '%s' "$specs" | grep -c . || true)

# 走査対象に spec が 1 件も無いのは、テストが消えた・改名された・走査対象外の
# ディレクトリへ移動した状態。green と区別できないと回帰に気付けないため失敗させる。
if [ "$spec_count" -eq 0 ]; then
  echo "run-busted: no *_spec.lua found under $TARGET" >&2
  exit 1
fi

# 実行前の静的検査。ハーネスの出力を信じる前に、spec 側の前提を確かめる。
for spec in $specs; do
  if ! grep -qE '(^|[^[:alnum:]_])it[[:space:]]*\(' "$spec"; then
    echo "run-busted: $spec defines no test (no it(...) found)" >&2
    exit 1
  fi
  # spec が自分でプロセスを終わらせると、plenary が本物のサマリを出す前に
  # 子プロセスが消え、偽のサマリだけが残る。テストが os.exit を呼ぶ理由は無い。
  if grep -qE '(^|[^[:alnum:]_.])os\.exit[[:space:]]*\(' "$spec"; then
    echo "run-busted: $spec calls os.exit, which prevents the harness from reporting real results" >&2
    exit 1
  fi
  # plenary は pending を Pending 行と Success 件数の両方に数えるため、全件 pending の
  # spec でも Success >= 1 になり実行後の検査をすり抜ける。加えて
  # rules/core/tdd.md が「後で追加する意図でテストをスキップする」ことを禁じているので、
  # 実行前に静的に落とす。
  if grep -qE '(^|[^[:alnum:]_.])pending[[:space:]]*\(' "$spec"; then
    echo "run-busted: $spec uses pending(); skipped tests are not allowed (see rules/core/tdd.md)" >&2
    exit 1
  fi
done

out=$(nvim --headless -u "$MINIMAL_INIT" \
  -c "PlenaryBustedDirectory $TARGET {minimal_init = '$MINIMAL_INIT', sequential = true}" 2>&1)
status=$?
printf '%s\n' "$out"

[ "$status" -eq 0 ] || exit "$status"

plain=$(printf '%s' "$out" | perl -pe 's/\e\[[0-9;]*m//g')
# plenary のサマリは `print("Success: ", n)` で出力され、Lua の print は引数間に
# タブを挟む。このタブを目印にすることで、テスト本体が print した
# `Success: 3` のような文字列を誤ってサマリと数えない。
summary_count=$(printf '%s\n' "$plain" | perl -ne '$n++ if /^Success:[ ]*\t\d+/; END { print $n + 0 }')

# サマリ行の数が spec ファイル数と一致しない場合、走査から漏れたファイルがあるか、
# テスト本体が偽のサマリ行を出力している。どちらも成功として扱ってはいけない。
if [ "$summary_count" -ne "$spec_count" ]; then
  echo "run-busted: expected $spec_count summary block(s) for $spec_count spec file(s), got $summary_count" >&2
  exit 1
fi

# 「1 件も成功しなかった spec」が 1 つでもあれば失敗させる。合計値で見ると、
# 別の spec の成功数に隠れて空の spec を見逃す。
if printf '%s\n' "$plain" | perl -ne 'exit 1 if /^Success:[ ]*\t0(\D|$)/' ; then
  :
else
  echo "run-busted: a spec file ran zero passing tests; every spec must run at least one test" >&2
  exit 1
fi

exit 0
