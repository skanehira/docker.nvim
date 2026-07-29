<!-- dev-spec:approved 2026-07-29 goals_sha=e708a6e6eb7fafda72bb76e4be959304b0006a4dab9171ac6769fc3c614109cd -->
# TODO: docker.nvim

作成日: 2026-07-29
生成元: dev-spec (todo-generation)
設計書: docs/DESIGN_DETAIL_APP.md + docs/DESIGN_DETAIL_INFRA.md (概要は docs/DESIGN.md)

## 概要

Neovim から Docker のコンテナ・イメージ・ボリューム・ネットワーク、および docker compose のサービス／プロジェクトを操作できるプラグインを新規に実装する。Lua で実装し、docker との通信は docker CLI のサブプロセス実行に限る。UI は Neovim 標準 API のフロートウィンドウで構成し、ランタイムの Lua ライブラリ依存を持たない。

実装の 1 周目は Must（US-001〜US-015）を通しで仕上げることを目標とし、フェーズ 1〜8 がこれに対応する。フェーズ 9 は残りの Should、フェーズ 10 は Could にあたる。

Must / Should / Could とフェーズの対応（Should の一部は、同じモジュールを触るため Must と同じフェーズに含めている）:

| フェーズ | 対応ストーリー | 優先度の内訳 |
| --- | --- | --- |
| 1〜4 | US-001、US-013、US-014 | Must |
| 5 | US-002〜US-005、US-015 / US-016、US-025、US-026 | Must ＋ Should（設定合成・操作の排他・単一バッファ化は同じモジュールで実装するため同居させる） |
| 6 | US-011、US-012 | Must |
| 7 | US-008〜US-010 | Must |
| 8 | US-006、US-007 / US-018〜US-020 | Must ＋ Should（ボリューム・ネットワーク・イメージ詳細はリソース定義の追加のみで済むため同居させる） |
| 9 | US-017、US-021〜US-024、US-027 | Should |
| 10 | US-028〜US-031 | Could |

CI の構築（フェーズ 11-b）は品質保証（フェーズ 11-a）の後に行う。CI の `e2e` ジョブが品質保証フェーズで作る `scripts/e2e.sh` を実行するため、先に CI を作っても検証できないことによる。

## 実装タスク

### フェーズ1: 基盤構築 <!-- deps: none -->

DESIGN_DETAIL_APP.md「1. プロジェクトセットアップ」に対応。

- [x] ディレクトリ構造の作成（`lua/docker/{resources,state,handlers,adapters/docker,views,ui}` / `plugin` / `doc` / `tests` / `scripts`）。空ディレクトリは git が追跡しないため `.gitkeep` を置き、clone 後も構成が残るようにする
- [x] `.luacheckrc` の作成（`vim` をグローバルとして許可）
- [x] `stylua.toml` の作成（インデント幅・行長の設定）
- [x] `.luarc.json` の作成（Neovim ランタイムパスを型解決に含める）
- [x] `tests/minimal_init.lua` の作成（plenary.nvim を `runtimepath` に追加）。plenary の場所は `PLENARY_PATH` で上書きでき、不在または plenary でないディレクトリを指している場合は `cquit 1` で即座に非 0 終了する（この検査が無いと `PlenaryBusted*` が未定義コマンドのままヘッドレス nvim がハングし、CI からは失敗ではなく無応答に見える）
- [x] `scripts/run-busted.sh` の作成（テストの起動と「実際に実行されたこと」の検証を集約）
- [x] `Makefile` の作成（`test` / `test-file` / `test-e2e` / `plugin-check` / `lint` / `format` / `format-check` / `typecheck` / `check`）
- [x] `lua/docker/notify.lua` の作成（情報・警告・エラーの通知を 1 箇所に集約）
- [x] [CHECK] 初回確認（`make lint` / `make format-check` / `make typecheck` / `make plugin-check` / `make test` がそれぞれ 0 で終了し、`make check` が全部を通す）

**検証器を空虚にしないための不変条件**（ゴールの検証手順がすべて `make test-file FILE=...` の終了コードに依存するため、ここが崩れると受入検証そのものが無意味になる）。判定は `scripts/run-busted.sh` / `scripts/typecheck.sh` / `scripts/plugin-check.sh` に集約する:

- `make test-file` は次をすべて非 0 で終了させる: `FILE` 未指定 / ファイル不在 / `*_spec.lua` でない / 実行後にテストが 1 件も成功していない
- `make test` は、走査対象に spec が 1 件も無い場合も非 0 で終了させる。フェーズ 1 着手時点の「テスト 0 件で正常終了」は足場が動くことの初回確認としてのみ実施し、恒久的な仕様としては採らない
- 実行前の静的検査として、各 spec が `it(...)` を 1 つ以上持つこと、`os.exit` を呼ばないこと、`pending(...)` を使わないことを確認する（`os.exit` を許すとハーネスが本当の結果を出力する前にプロセスが消えて偽のサマリだけが残る。`pending` は plenary が Pending 行と `Success` の件数の両方に数えるため、全件 pending でも実行後の検査をすり抜ける。あわせて `rules/core/tdd.md` の「後で追加する意図でテストをスキップしない」にも対応する）
- 実行後は、spec ファイル 1 つにつきサマリブロックがちょうど 1 つ出ること、かつ `Success: 0` のサマリが 1 つも無いことを検査する（合計値で見ると、別 spec の成功数に隠れて空の spec を見逃す）。サマリ行の判定には plenary の `print` が挟むタブを使い、テスト本体が出力した `Success: 3` のような文字列と区別する
- `make spec-layout-check` は `lua/` と `tests/e2e/` の外にある spec を検出する（`make test` が走査しないため、置いても一度も実行されない）
- `make typecheck` は `VIMRUNTIME` と plenary のパスを解決できない場合に検査せず失敗させる（解決できないまま実行すると型エラーがあっても "no problems found" で素通りする）
- `make plugin-check` は `plugin/*.lua` の読み込みエラーを stderr で検出する（テストから require されないため他のどのゲートにも掛からない。`v:errmsg` では `vim.schedule` / `VimEnter` 内のエラーを取りこぼす）

**これらのゲートが保証しないこと**（後続フェーズで「ゲートが拾ってくれる」と誤認しないために明記する）:

- spec が対応する実装を実際に検証しているかは判定できない。`assert.are.same(1, 1)` だけの spec でもゴール検証は通る。これは `review-tdd` / `review-adversarial` の責務であり、終了コードでは代替できない
- 一部の spec だけが削除された場合は検出できない（spec 数とサマリ数が同時に減るため常に一致する）
- `it` の本体を空にする、`assert` を消す、条件分岐で実質何も検証しない形にするなど、テストの「中身」を弱めた場合は検出できない（実行はされ、成功も 1 件以上出るため）

### フェーズ2: docker CLI アダプタの実装 <!-- deps: 1 -->

DESIGN_DETAIL_APP.md「3.2 アダプタ層」「5. docker コマンド仕様」「8. エラー戦略」に対応。US-013（非同期実行）・US-014（環境エラーの区別）。

- [ ] [RED] 出力テンプレート組み立てのテストを作成（`format.lua`: フィールド指定から `{{json ...}}` 形式のテンプレート文字列を生成する）
- [ ] [GREEN] テンプレート組み立ての実装
- [ ] [RED] NDJSON 解析のテストを作成（PoC 採取の実データを `tests/fixtures/` に置き、ラベル値にカンマ・引用符・改行・偽の compose ラベルを含むケース、空行、解析不能な行を含める）
- [ ] [GREEN] NDJSON 解析の実装（解析できない行は読み飛ばして件数を記録する）
- [ ] [RED] コマンド実行と結果型のテストを作成（成功・非 0 終了・stderr の伝播。実行器を差し替えて docker 無しで検証する）
- [ ] [GREEN] `cli.run` と `docker.Result` の実装（`vim.system` による非同期実行、`_set_executor` の差し替え口）
- [ ] [RED] 接続確認のテストを `lua/docker/adapters/docker/cli_spec.lua` に作成（docker 未検出・デーモン未起動・ソケット権限不足の 3 状況で異なるメッセージが返ること）
- [ ] [GREEN] `cli.check_connection` の実装（stderr の内容で 3 状況を判別する）
- [ ] [RED] デバッグログのテストを作成（既定では出力されない、`debug` を有効にすると実行した docker コマンド・終了コード・解析に失敗した行数が出力される）
- [ ] [GREEN] デバッグログ出力の実装（`notify.lua` にデバッグ用の出力経路を追加し、`cli.run` から呼ぶ）
- [ ] [REFACTOR] 引数組み立てと結果生成の重複を整理する
- [ ] [REVIEW] フェーズ実装の簡易セルフレビューと修正
- [ ] [CHECK] `make lint` / `make format-check` / `make typecheck` / `make test` の実行と確認

### フェーズ3: リソース定義とリソースストアの実装 <!-- deps: 1,2 -->

DESIGN_DETAIL_APP.md「3.3 リソース定義」「3.4 リソースストア」「4. データ構造」に対応。DOMAIN_MODEL.md の INV-1。

- [ ] [RED] コンテナのリソース定義のテストを `lua/docker/resources/registry_spec.lua` に作成（一覧取得の引数に `-a`（停止中を含む全件取得、BR-022）と `--no-trunc` が含まれること、`.Size` を参照しないこと、生データからカラム値と compose 列が取り出されること、非 compose コンテナで compose 列が空文字列になること）
- [ ] [GREEN] `registry.lua` にコンテナ定義を実装
- [ ] [RED] compose ラベル判定のテストを作成（`oneoff=True` をサービスに紐付けない、偽のラベルを仕込んだ値で誤判定しない）
- [ ] [GREEN] `fields.lua` に compose ラベル判定と状態・ポートの取り出しを実装
- [ ] [RED] リソースストアのテストを `lua/docker/state/store_spec.lua` に作成（全置換・追加更新・削除、同一種別に同一 ID が重複しない、購読者への通知）
- [ ] [GREEN] `state/store.lua` の実装
- [ ] [REFACTOR] 定義の共通部分（ID の取り出し・カラム生成）を整理する
- [ ] [REVIEW] フェーズ実装の簡易セルフレビューと修正
- [ ] [CHECK] `make check` の実行と確認

### フェーズ4: UI 基盤と一覧ビューの実装 <!-- deps: 1,2,3 -->

DESIGN_DETAIL_APP.md「2. ディレクトリ構造」の `ui/` と `views/list.lua`、「6.3 入出力」に対応。US-001。

- [ ] [RED] カラム幅算出と行整形のテストを作成（各列の最大幅に揃う、値に全角文字が含まれる場合の桁揃え、空値の扱い）
- [ ] [GREEN] `ui/table.lua` の実装
- [ ] [RED] ハイライト適用位置のテストを作成（状態カラムの範囲に状態別のハイライトが付く）
- [ ] [GREEN] `ui/highlight.lua` の実装（`DockerStatusRunning` などのハイライトグループ定義と extmark による適用）
- [ ] [RED] ウィンドウ生成のテストを作成（フロートウィンドウが `border` とタイトルを持つ、カラムヘッダーが `winbar` に入る、バッファが `buftype=nofile` かつ `nomodifiable`、`VimResized` で追従する）
- [ ] [GREEN] `ui/window.lua` の実装（`zindex` による重ね合わせに対応させる）
- [ ] [RED] 一覧ビューの描画テストを `lua/docker/views/list_spec.lua` に作成（リソース集合からバッファ行が生成される、compose 列の値、非 compose コンテナで空欄になる、0 件のときの表示、カーソル行からリソースを特定できる、各リソース種別の一覧が描画される）
- [ ] [GREEN] `views/list.lua` と `state/view.lua` の実装
- [ ] [RED] 状態表示のテストを `lua/docker/views/list_status_spec.lua` に作成（ストア上のコンテナ状態が変わると STATUS 列の文字列とハイライトが変わる）
- [ ] [GREEN] 状態カラムの描画とハイライト適用を実装
- [ ] 200 件のコンテナで一覧の取得から描画までの所要時間を計測し、NFR-4 の目標値（初回描画 500 ms 以内）を満たすか確認する。結果を DESIGN_DETAIL_APP.md 11.3 の `large-list-performance` に反映し、満たさない場合は差分更新または表示上限の導入を判断する
- [ ] [REFACTOR] ビュー状態の更新を不変更新に統一する
- [ ] [REVIEW] フェーズ実装の簡易セルフレビューと修正
- [ ] [CHECK] `make check` の実行と確認

### フェーズ5: コントローラ・キーマップ・コンテナ操作の実装 <!-- deps: 1,2,3,4 -->

DESIGN_DETAIL_APP.md「3.1 公開 API」「6.2 キーマップ」「7.2 コンテナ操作」に対応。US-002〜US-005、US-015、US-016、US-025、US-026。

- [ ] [RED] 設定合成のテストを `lua/docker/config_spec.lua` に作成（デフォルトと利用者設定の深い合成、一部ビューのみ指定したとき他はデフォルト、未知のビュー種別・アクション名を無視して通知する、`debug` オプションの既定が false であること、キーマップがバッファローカルに設定されること）
- [ ] [GREEN] `config.lua` の実装（デフォルトのキーマップ定義と `debug` オプションを含む）
- [ ] [RED] Neovim バージョン検査のテストを作成（0.10 未満では対応バージョンを示すメッセージが出て、コマンドとキーマップが登録されない）
- [ ] [GREEN] `setup()` でのバージョン検査と機能無効化を実装
- [ ] [RED] Ex コマンドのテストを作成（`:Docker containers` などが対応するビューを開く、未知のサブコマンドと引数なしで使い方のメッセージを出す）
- [ ] [GREEN] `plugin/docker.lua` の実装（`:Docker` の定義と `<Plug>` マッピングの公開）
- [ ] [RED] キーマップ解決のテストを作成（ビュー種別ごとに有効なアクションのみ解決される、同じキーがビューごとに別アクションへ割り当てられる）
- [ ] [GREEN] `views/keymaps.lua` の実装
- [ ] [RED] ビューを開く処理のテストを作成（同じリソース種別のビューが既にある場合は新規バッファを作らず既存へ移動する、キーマップがバッファローカルに設定される）
- [ ] [GREEN] `init.lua` の `setup` / `open` / `close` と `handlers/lifecycle.lua` の実装
- [ ] [RED] 実行中操作の台帳のテストを `lua/docker/handlers/operations_spec.lua` に作成（同一対象・同一操作の二重受け付けを拒否する、完了で解除される）
- [ ] [GREEN] `handlers/operations.lua` の実装
- [ ] [RED] 実行中表示のテストを `lua/docker/views/list_status_spec.lua` に追加（操作の開始で対象行に実行中を示す印が現れ、完了で消える）
- [ ] [GREEN] 一覧ビューへの実行中表示を実装
- [ ] [RED] ジョブ台帳のテストを `lua/docker/handlers/jobs_spec.lua` に作成（起動したジョブが登録される、`VimLeavePre` で全ジョブが停止する）
- [ ] [GREEN] `handlers/jobs.lua` の実装
- [ ] [RED] コンテナ操作のテストを `lua/docker/handlers/actions_spec.lua` に作成（start / stop / restart / kill が発行する docker 引数、前提を満たさない操作で docker を呼ばずに警告する、失敗時に内部状態を変更しない）
- [ ] [GREEN] `handlers/actions.lua` にコンテナのライフサイクル操作を実装
- [ ] [RED] 削除操作のテストを `lua/docker/handlers/actions_delete_spec.lua` に作成（確認プロンプトで `y` のときのみ削除コマンドが発行される、強制削除オプションを付けない）
- [ ] [GREEN] 削除アクションの実装
- [ ] [RED] ターミナル起動のテストを `lua/docker/handlers/terminal_spec.lua` に作成（ログ追従・シェル起動・コマンド実行が発行する引数、バッファ破棄でジョブ台帳から消えること）
- [ ] [GREEN] `handlers/terminal.lua` の実装（シェルは bash があれば bash、なければ sh）
- [ ] [RED] ヘルプビューのテストを `lua/docker/views/help_spec.lua` に作成（キーマップ定義から一覧が生成される、そのビューで無効な操作が載らない、`q` で直前のビューへ戻る）
- [ ] [GREEN] `views/help.lua` の実装
- [ ] [REFACTOR] アクションの前提検査と実行の流れを共通化する
- [ ] [REVIEW] フェーズ実装の簡易セルフレビューと修正
- [ ] [CHECK] `make check` の実行と確認

### フェーズ6: ライブ更新と手動再取得の実装 <!-- deps: 1,2,3,4,5 -->

DESIGN_DETAIL_APP.md「5.2 イベント購読」「7.1 一覧を開いてライブ更新が始まるまで」「7.4 イベント購読の切断と回復」に対応。US-011、US-012。

- [ ] [RED] イベント解析のテストを `lua/docker/adapters/docker/events_spec.lua` に作成（行の途中で分割されたチャンク列から完全なイベントを組み立てる、複数行が 1 チャンクで届く場合、巨大な 1 行、volume の名前が `Actor.ID` から取れること、`timeNano` を使わないこと）
- [ ] [GREEN] `adapters/docker/events.lua` の受信・組み立て・解析を実装
- [ ] [RED] 購読の開始と停止のテストを作成（意図的な停止でジョブが登録解除される、停止フラグにより切断と区別される）
- [ ] [GREEN] 購読の開始・停止の実装
- [ ] [RED] イベントからストア更新までのテストを作成（create / start / stop / destroy が追加・更新・削除に対応する、既に消えた対象の取得失敗を通知しない）
- [ ] [GREEN] イベント受信時のストア更新を実装
- [ ] [RED] 描画デバウンスのテストを `lua/docker/handlers/render_spec.lua` に作成（連続する更新要求が 1 回にまとめられる、再描画後にカーソル位置が保持される、偽の時計でイベント受信から 1 秒以内に描画要求が出ることを検査する）
- [ ] [GREEN] `handlers/render.lua` の実装
- [ ] [RED] 切断と再購読のテストを `lua/docker/adapters/docker/events_reconnect_spec.lua` に作成（切断を検知して通知する、待機時間を延ばしながら最大 5 回再試行する、成功時に全件再取得で整合させる、5 回失敗で手動更新を促す）
- [ ] [GREEN] 再購読処理の実装
- [ ] [RED] 手動再取得のテストを `lua/docker/handlers/actions_refresh_spec.lua` に作成（`R` で再取得と再描画が行われカーソル位置が保たれる、購読が停止していれば再開される）
- [ ] [GREEN] `refresh` アクションの実装
- [ ] [RED] ビュー破棄時の後始末のテストを作成（`q` / `:bd` / タブを閉じる のいずれでも購読ジョブが停止する）
- [ ] [GREEN] ビュー破棄時の購読停止を実装
- [ ] [REFACTOR] 購読の状態遷移（購読中・切断・再試行中・断念）を整理する
- [ ] [REVIEW] フェーズ実装の簡易セルフレビューと修正
- [ ] [CHECK] `make check` の実行と確認

### フェーズ7: compose 対応の実装 <!-- deps: 1,2,3,4,5,6 -->

DESIGN_DETAIL_APP.md「5.3 compose」「7.3 compose サービス一覧の組み立て」に対応。US-008〜US-010。

- [ ] [RED] compose プロジェクト解決のテストを `lua/docker/adapters/docker/compose_spec.lua` に作成（`config --format json` の出力から名前とサービス全件を取り出す、終了コードと stderr で「compose サブコマンドが使えない」「compose 外」「compose ファイルが不正」の 3 区分を判別する）
- [ ] [GREEN] `adapters/docker/compose.lua` の `resolve_project` を実装
- [ ] [RED] サービス一覧の組み立てテストを作成（サービス名とコンテナのラベルの突き合わせ、単発コンテナの除外、対応が無いサービスの状態が `none` になること）
- [ ] [GREEN] サービスの解決処理を実装
- [ ] [RED] サービス一覧ビューのテストを作成（SERVICE / STATUS / CONTAINER のカラム、compose プロジェクト外でビューを開かずメッセージを出すこと）
- [ ] [GREEN] サービス一覧のリソース定義とビューを実装
- [ ] [RED] サービス操作のテストを `lua/docker/handlers/actions_compose_spec.lua` に作成（up / stop / restart / logs が発行する compose 引数、ビューを開いた時点の作業ディレクトリで実行されること、デタッチで起動すること、コンテナが無いサービスのログでターミナルを開かないこと）
- [ ] [GREEN] サービス単位のアクションを実装
- [ ] [RED] プロジェクト操作のテストを同ファイルに追加（`U` が `up -d`、`D` が確認を経て `down` を発行する、実行中の重複要求を拒否する）
- [ ] [GREEN] プロジェクト単位のアクションを実装
- [ ] [RED] サービス一覧のライブ更新テストを作成（コンテナのイベントから compose ラベル経由で該当サービスの状態が更新される）
- [ ] [GREEN] サービス一覧のイベント連動を実装
- [ ] [REFACTOR] compose 呼び出しの引数組み立てを共通化する
- [ ] [REVIEW] フェーズ実装の簡易セルフレビューと修正
- [ ] [CHECK] `make check` の実行と確認

### フェーズ8: 詳細ビューと残りのリソース種別の実装 <!-- deps: 1,2,3,4,5,6,7 -->

DESIGN_DETAIL_APP.md「4.2 イメージ / ボリューム / ネットワーク」「5.4 その他の操作」に対応。US-006、US-007、US-018〜US-020。

- [ ] [RED] 詳細ビューのテストを `lua/docker/views/inspect_spec.lua` に作成（`docker inspect` の結果が JSON として表示される、`q` で直前の一覧に戻りカーソル位置が復元される、取得失敗時にビューを開かない）
- [ ] [GREEN] `views/inspect.lua` とビュースタックの実装
- [ ] [RED] イメージのリソース定義のテストを `lua/docker/resources/registry_spec.lua` に追加（カラム構成、`.Label` を使わないこと、一覧取得と削除コマンドの引数）
- [ ] [GREEN] イメージ定義と一覧・削除を実装
- [ ] [RED] ボリューム・ネットワークのリソース定義のテストを同ファイルに追加（カラム構成、一覧取得と削除コマンドの引数、組み込みネットワークの削除失敗が docker のエラーとして伝わること）
- [ ] [GREEN] ボリューム・ネットワークの定義と一覧・削除を実装
- [ ] [RED] 0 件表示のテストを `lua/docker/views/list_spec.lua` に追加（各リソース種別で空である旨が表示されエラーにならない）
- [ ] [GREEN] 0 件表示の実装
- [ ] [REFACTOR] 削除処理を種別に依存しない形へ統一し、`lua/docker/handlers/actions_delete_spec.lua` に全リソース種別で確認プロンプトを経ることのテストを追加する
- [ ] [REVIEW] フェーズ実装の簡易セルフレビューと修正
- [ ] [CHECK] `make check` の実行と確認

### フェーズ9: 拡張機能の実装 <!-- deps: 1,2,3,4,5,6,7,8 -->

USER_STORIES.md の Should（US-017、US-021〜US-024、US-027）に対応。

- [ ] [RED] 使い捨て実行のテストを作成（`docker run --rm -it` の引数、シェルが無いイメージでの失敗の扱い）
- [ ] [GREEN] `quickrun` アクションの実装
- [ ] [RED] 公開ポートの URL 組み立てテストを作成（`0.0.0.0` / `::` を `localhost` に読み替える、複数ポートで選択を求める、ポートが無い場合の通知）
- [ ] [GREEN] `open_browser` アクションの実装
- [ ] [RED] ファイルコピーのテストを作成（`ct` / `cf` が発行する `docker cp` の引数、入力キャンセル時に実行しない、失敗時に docker のエラーを通知する）
- [ ] [GREEN] `copy_to` / `copy_from` アクションの実装
- [ ] [RED] コンテナ内ファイル編集のテストを作成（バッファ名が `docker://<container>/<path>` になる、同一パスを別コンテナで開いても書き戻し先が一意に決まる、保存で書き戻しが発行される、失敗時に modified が保持される、存在しないパスでバッファを開かない）
- [ ] [GREEN] `edit_file` アクションと保存フックの実装
- [ ] [RED] ビュー切替のテストを作成（`<Tab>` で選んだ種別の一覧が同じウィンドウに表示される、戻ったときにカーソル位置が復元される、compose 外でサービス一覧へ切り替えると切替前が維持される）
- [ ] [GREEN] `switch_view` アクションの実装
- [ ] [RED] 全ビューのライブ更新テストを作成（イメージ・ボリューム・ネットワーク・サービスの各一覧がイベントで更新される）
- [ ] [GREEN] 各リソース定義へのイベント種別の対応付けを実装
- [ ] [REFACTOR] 入力を伴うアクション（パス・コマンド・選択）の共通処理を整理する
- [ ] [REVIEW] フェーズ実装の簡易セルフレビューと修正
- [ ] [CHECK] `make check` の実行と確認

### フェーズ10: 追加機能の実装 <!-- deps: 1,2,3,4,5,6,7,8,9 -->

USER_STORIES.md の Could（US-028〜US-031）に対応。

- [ ] [RED] ドリルダウンのテストを作成（コンテナからイメージへ、サービスからコンテナへ移動し対象にカーソルが当たる）
- [ ] [GREEN] `drilldown` アクションの実装
- [ ] [RED] 一括削除のテストを作成（Visual モードの選択範囲が対象になる、確認に件数が含まれる、一部失敗時に成功分は削除され失敗分がまとめて通知される）
- [ ] [GREEN] 一括削除の実装
- [ ] [RED] pause / unpause のテストを `lua/docker/handlers/actions_spec.lua` に追加（発行する引数、停止中コンテナへの pause と一時停止していないコンテナへの unpause を拒否する）
- [ ] [GREEN] `pause` / `unpause` アクションの実装
- [ ] [RED] 絞り込みのテストを `lua/docker/views/list_filter_spec.lua` に作成（`<C-f>` で部分一致する行のみ表示される、解除で全行に戻る、`/` は Neovim 本来の検索として残る）
- [ ] [GREEN] `filter` アクションの実装
- [ ] [REFACTOR] ビュー状態（フィルタ）の持ち方を整理する
- [ ] [REVIEW] フェーズ実装の簡易セルフレビューと修正
- [ ] [CHECK] `make check` の実行と確認

### フェーズ11-a: 品質保証 <!-- deps: 1,2,3,4,5,6,7,8,9,10 -->

DESIGN_DETAIL_APP.md「9. 検証手順」「10. テスト戦略」に対応。CI（フェーズ 11-b）の `e2e` ジョブが本フェーズで作る `scripts/e2e.sh` を実行するため、品質保証を先に行う。

- [ ] [STRUCTURAL] モジュール構成とヘルパの整理（動作変更なし）
- [ ] `doc/docker.txt` の作成（コマンド・キーマップ・設定項目のヘルプ）
- [ ] `README.md` の作成（前提・インストール・使い方・キーマップ一覧）
- [ ] `scripts/e2e.sh` の作成（docker の利用可否確認、検証用リソースの作成、headless Neovim での通し実行、後始末。終了コードは 0=成功 / 1=assert 失敗 / 2=docker 利用不可）
- [ ] [RED] G_E2E の通しシナリオを `tests/e2e/e2e_spec.lua` に作成（コンテナ一覧と compose 列・コンテナの停止と起動が STATUS に反映される・削除の確認プロンプトと削除・ログ追従のターミナルを開いて閉じたときに `docker logs -f` のプロセスが残らない・シェル起動・サービス一覧の `none`・サービス単位の起動・プロジェクトの `U` と `D`・images / volumes / networks の一覧・詳細ビューの往復・ヘルプ表示・別プロセスの操作が 1 秒以内に反映・`R` での再取得）
- [ ] [GREEN] G_E2E が通るまでの不足を実装する
- [ ] 全テストの実行と確認（単体・結合・E2E）
- [ ] ゴール G1〜G13 の検証コマンドを 1 件ずつ実行し、DESIGN.md のゴールと突き合わせる
- [ ] Neovim 終了時のプロセス残留確認（一覧とターミナルを開いたまま `:qa` し、子プロセスが 0 件になること）
- [ ] [REVIEW] フェーズ実装の簡易セルフレビューと修正
- [ ] [CHECK] `make check` の実行と確認。あわせて G_E2E の通しシナリオ（`make test-e2e`）を実行して green を確認する

### フェーズ11-b: CI 構築とリリース <!-- deps: 1,2,3,4,5,6,7,8,9,10,11-a -->

DESIGN_DETAIL_INFRA.md「2.2 バージョニング」「3. CI/CD パイプライン」に対応。宣言的な設定のため TDD サイクルは付けない。

- [ ] `.github/workflows/ci.yml` の作成（`push`（デフォルトブランチ）と `pull_request` をトリガーにする）
- [ ] `test` ジョブの定義（Neovim 0.10.0 と stable のマトリクス、plenary.nvim を clone して `make test`）
- [ ] `lint` / `format` / `typecheck` ジョブの定義
- [ ] `e2e` ジョブの定義（ランナー同梱の docker を使って `make test-e2e`）
- [ ] リポジトリ設定（`main` への直接プッシュ禁止、プルリクエストと全ジョブ成功を必須にするブランチ保護）
- [ ] 初回タグ `v0.1.0` の付与とリリースノートの作成（INFRA 2.2 のバージョニング方針に従う）
- [ ] [CHECK] CI-1〜CI-4 の検証（プルリクエストで 5 ジョブが実行され成功する、`test` が 2 バージョンで展開される、失敗コミットでマージがブロックされる、workflow に `GITHUB_TOKEN` 以外の `secrets` 参照が無い）

## 実装ノート

### 実装上の必須事項

DESIGN_DETAIL_APP.md「11.4 実装上の注意」より、PoC で判明した踏みやすい落とし穴:

- 一覧取得では `--no-trunc` を必ず付ける（付けないと ID が 12 文字、Command が 20 文字で切り詰められる）
- `Labels` フィールドを分割してラベルを取り出してはならない。`.Label` によるキー名指しを使う（分割すると誤った値を掴む）
- イベントの `timeNano` は使わない（浮動小数点化で下位桁が落ちる）。再購読の起点には `time` を使う
- ボリュームのイベントでは名前が `Actor.ID` に入る
- イベント購読のジョブを止めるときは、先に意図的な停止フラグを立てる
- `docker events` にはデーモン全体のイベントが流れるため、デバウンスを前提に組む
- 一覧のヘッダーはバッファに入れず `winbar` に置く
- `docker compose config --services` は出力順が非決定的なので使わない。`config --format json` に一本化する

### MUST ルール遵守事項

- TDD: RED → GREEN → REFACTOR → REVIEW → CHECK サイクルを厳守
- REVIEW: 各フェーズ完了時に簡易セルフレビューを実施し、問題があればその場で修正
- CHECK: REVIEW 後に lint / format / typecheck / test を実行して最終確認
- Tidy First: 構造変更と動作変更を分離
- コミット: `[BEHAVIORAL]` または `[STRUCTURAL]` プレフィックス必須
  - `[BEHAVIORAL]`: 動作を変更するコミット（機能追加、バグ修正、テスト追加）
  - `[STRUCTURAL]`: 動作を変更しないコミット（リファクタリング、フォーマット、コメント追加）
- 外界（docker コマンドの実行・ジョブ起動・時刻）はすべてアダプタ層に閉じ込め、テストで差し替えられるようにする

### 参照ドキュメント

- 概要設計: docs/DESIGN.md
- アプリ詳細設計: docs/DESIGN_DETAIL_APP.md
- インフラ詳細設計: docs/DESIGN_DETAIL_INFRA.md
- ユースケース・ビジネスルール: docs/USECASES.md
- 用語集: docs/GLOSSARY.md
- ドメインモデル・不変条件: docs/DOMAIN_MODEL.md
- PoC 結果: docs/FEASIBILITY.md
