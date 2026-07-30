# 実現可能性検証（Feasibility Check）

- 種別: 技術検証計画・結果
- 対象: docker.nvim
- 前提ドキュメント: [USECASES.md](USECASES.md), [USER_STORIES.md](USER_STORIES.md)
- 作成日: 2026-07-29

## 依拠する外部事実（2026-07-29 時点で実機確認済み）

| 事実 | 値 | 確認方法 |
| --- | --- | --- |
| Neovim | v0.13.0-nightly | `nvim --version` |
| Docker CLI | 29.4.0 | `docker --version` |
| Docker Compose | v5.1.2（`docker compose` サブコマンド形式） | `docker compose version` |
| Docker デーモン | 稼働中（ServerVersion 29.4.0） | `docker info` |
| nui.nvim | 導入済み（`~/.local/share/nvim/lazy/nui.nvim`） | ディレクトリ確認 |
| plenary.nvim | 導入済み（テスト実行に使用） | ディレクトリ確認 |
| `docker ps -a --format json` | 1 行 1 JSON（NDJSON）。`Labels` はカンマ区切りの文字列、一部フィールドは表示幅で省略される（例: `"Mounts":"buildx_buildki…"`） | 実行して出力を確認 |

## 技術的不確実性の一覧

| ID | 不確実性 | 分類 | 影響度 | 発生確率 | リスク |
| --- | --- | --- | --- | --- | --- |
| R-1 | 一覧取得時に compose ラベルを欠損・誤解析なく取得できるか | 技術的実現性 | 致命的 | 高 | 🔴 最優先 |
| R-2 | `docker events` のストリームを Neovim のジョブで安定して受信・解析できるか | 技術的実現性 | 致命的 | 高 | 🔴 最優先 |
| R-3 | compose プロジェクトの判定とサービス一覧の取得を CLI に委ねて成立するか | 統合 | 重大 | 中 | 🔴 最優先 |
| R-4 | UI 基盤に nui.nvim を使うか、Neovim 標準 API のみで構成するか | 技術的実現性 | 重大 | 中 | 🟡 優先 |
| R-5 | コンテナ内ファイルの編集・書き戻しを Neovim の書き込みフックで実現できるか | 技術的実現性 | 中程度 | 中 | 🟢 通常 |
| R-6 | コンテナが多数ある環境で一覧描画とライブ更新が実用的な速度か | パフォーマンス | 中程度 | 低 | 🟢 通常 |

---

## PoC: 一覧取得と compose ラベルの解析

**id**: docker-list-json-labels
**目的**: `docker ps` などの一覧取得で、compose ラベル（`com.docker.compose.project` / `.service` / `.oneoff`）と表示に必要な全フィールドを、欠損・誤解析なく取得できる出力形式を確定する
**risk**: high
**blocker**: true
**対象リスク**: R-1

**スコープ**:

- 含む: コンテナ一覧の取得形式の決定（`--format json` / `--format '{{json .}}'` / `--no-trunc` / `docker inspect` の併用）、ラベル値にカンマ・イコールを含む場合の解析可否、イメージ・ボリューム・ネットワーク一覧の同等確認
- 含まない: 一覧の描画方法、ソート順

**実装内容**:

1. compose ラベルを持つコンテナを起動する（`com.docker.compose.project.config_files` のように値にパスやカンマを含むラベルを含む状態を作る）
2. `docker ps -a --format json`、`docker ps -a --no-trunc --format json`、`docker ps -a --format '{{json .}}'` の出力を比較し、フィールドの省略（`…` による truncation）が起きる条件を特定する
3. `Labels` フィールドからラベルを解析し、値にカンマ・イコールを含むケースで正しく分解できるか確認する。できない場合は `--filter label=` や `docker inspect --format '{{json .Config.Labels}}'` などの代替手段を評価する
4. `docker image ls` / `docker volume ls` / `docker network ls` でも JSON 出力とフィールドの省略有無を確認する

**成功基準**:

- コンテナ名・イメージ・状態・ポート・compose ラベルのすべてが、省略記号を含まない完全な値として取得できるコマンド列が 1 つ以上確定する
- ラベル値にカンマ・イコールが含まれても、project 名と service 名を正しく取り出せることを実データで確認できる
- 1 回の docker 実行で全件分を取得できる（コンテナごとの追加実行を必須としない）

**失敗した場合の代替案**:

- 一覧は `docker ps --format '{{json .}}'` で取得し、ラベルのみ `docker inspect` で必要な対象だけ補完する（実行回数は増えるが確実）
- それも不十分なら、一覧取得自体を `docker inspect $(docker ps -aq)` に切り替える

**判断**: 成功 → 確定した形式を詳細設計のデータ取得仕様に反映 / 失敗 → 代替案の実行回数を評価して採用

<!-- POC_STATUS: id=docker-list-json-labels, blocker=true, status=verified, confidence=0.9 -->

---

## PoC: docker events のストリーム購読

**id**: docker-events-stream
**目的**: `docker events` の JSON ストリームを Neovim のジョブで受信し、チャンク分割された出力を正しく組み立てて一覧のライブ更新に使えることを確認する
**risk**: high
**blocker**: true
**対象リスク**: R-2

**スコープ**:

- 含む: `jobstart` によるストリーム受信、部分行・複数行が 1 チャンクで届く場合の処理、対象リソース種別（container / image / volume / network）のイベント取得可否、ジョブ終了時のプロセス後始末、ストリーム切断の検知
- 含まない: 再購読のバックオフ間隔の最終決定、描画のデバウンス値の最終決定

**実装内容**:

1. Neovim を headless で起動し、`docker events --format '{{json .}}'` を `jobstart` で購読する Lua スクリプトを実行する
2. 別プロセスでコンテナの作成・起動・停止・削除、イメージの取得・削除、ボリューム・ネットワークの作成・削除を行う
3. 受信したチャンクを行単位に組み立て、`vim.json.decode` で解析できた件数と、送出した操作の件数が一致するか確認する
4. ジョブを停止した後に `docker events` のプロセスが残っていないか（`pgrep`）確認する
5. docker デーモンを停止してストリームを切断させ、`on_exit` で検知できることを確認する

**成功基準**:

- 送出した操作すべてに対応するイベントを取りこぼしなく解析できる（イベント種別と対象 ID が取れる）
- container 以外（image / volume / network）のイベントも同一ストリームから取得できる
- ジョブ停止後に子プロセスが残らない
- ストリーム切断を検知できる（切断が検知不能なら自動再購読が設計できない）

**失敗した場合の代替案**:

- イベントのフィルタを `--filter type=container` 等に分けて複数ジョブで購読する
- ストリーム購読が不安定なら、一定間隔のポーリング（`docker ps` の再実行）へフォールバックし、`R` の手動更新を主経路にする

**判断**: 成功 → イベント駆動の更新機構を採用 / 失敗 → ポーリング方式へ切り替え、USER_STORIES.md の US-011 の受け入れ基準を見直す

<!-- POC_STATUS: id=docker-events-stream, blocker=true, status=verified, confidence=0.85 -->

---

## PoC: compose プロジェクトの判定とサービス一覧

**id**: compose-project-detection
**目的**: compose プロジェクトの判定・サービス一覧・プロジェクト名の解決を `docker compose` CLI に委ねる方式（BR-004）が成立することを確認する
**risk**: medium
**blocker**: true
**対象リスク**: R-3

**スコープ**:

- 含む: `docker compose config --quiet` の終了コードによる判定、`config --services` によるサービス名取得、プロジェクト名の取得手段、compose ファイルがサブディレクトリにある場合・`name:` でディレクトリ名と異なる場合の挙動、compose v5 系での互換性
- 含まない: 複数プロジェクトの同時表示

**実装内容**:

1. compose ファイルを持つディレクトリと持たないディレクトリで `docker compose config --quiet` を実行し、終了コードの差を確認する
2. `docker compose config --services` の出力形式（1 行 1 サービス名）を確認する
3. `name:` でディレクトリ名と異なるプロジェクト名を指定した compose ファイルを用意し、プロジェクト名を取得する手段を確認する（`docker compose config --format json` のトップレベル `name` など）
4. コンテナのラベル `com.docker.compose.project` と、3 で取得したプロジェクト名が一致することを確認する
5. サービスが定義されているがコンテナが未起動の状態で、サービス一覧に `none` として出せることを確認する

**成功基準**:

- compose プロジェクト内外を終了コードだけで判定できる
- 定義済みサービス名の全件が取得できる（未起動のサービスを含む）
- プロジェクト名を CLI から取得でき、コンテナのラベル値と突き合わせられる
- 1〜4 が compose v5.1.2 で動作する

**失敗した場合の代替案**:

- プロジェクト名の取得が困難なら、カレントディレクトリ名をプロジェクト名とみなし、一致しない場合はコンテナのラベルから逆引きする（lazydocker と同じ方式）
- `config --services` が使えないなら、compose 由来コンテナのラベルからサービスを導出する（未起動サービスは表示できないという制約を受け入れ、US-008 の受け入れ基準を見直す）

**判断**: 成功 → CLI 委譲方式で詳細設計 / 失敗 → 代替案を採用し、影響するストーリーの受け入れ基準を修正

<!-- POC_STATUS: id=compose-project-detection, blocker=true, status=verified, confidence=0.92 -->

---

## PoC: UI 基盤の選定

**id**: ui-foundation-choice
**目的**: 一覧・詳細・ヘルプの各ビューを実現する UI 基盤として、nui.nvim を依存に加えるか、Neovim 標準 API のみで構成するかを決める
**risk**: medium
**blocker**: true
**対象リスク**: R-4

**スコープ**:

- 含む: ヘッダー付きの一覧レイアウト、カラム整形、状態別ハイライト、ビューの重ね合わせ（一覧→詳細→ヘルプ）の実装コスト比較
- 含まない: 配色の最終決定、アイコン対応

**実装内容**:

1. Neovim 標準 API（`nvim_open_win` / `nvim_buf_set_lines` / `nvim_buf_add_highlight` またはエクステンションマーク）だけで、ヘッダー行と一覧本体を持つビューを試作する
2. 同じものを nui.nvim（`NuiPopup` / `NuiLayout`）で試作し、コード量・レイアウト崩れの扱い・ウィンドウのリサイズ追従を比較する
3. NFR-5（ランタイム依存を最小限に保つ）に照らして採否を判断する

**成功基準**:

- どちらの方式でも、ヘッダー・一覧・状態ハイライトを持つビューが表示できることを実機で確認できる
- 標準 API のみで実現した場合の追加コード量が、nui.nvim 依存を避ける価値に見合うかを、実際の試作コードの行数で比較できる

**失敗した場合の代替案**:

- 標準 API のみでのレイアウト維持が困難なら、nui.nvim を唯一のランタイム依存として採用する（k8s.nvim と同じ構成）

**判断**: 標準 API で十分 → 依存なしで設計 / 実装コストが高い → nui.nvim を採用し NFR-5 の記述を更新

<!-- POC_STATUS: id=ui-foundation-choice, blocker=true, status=verified, confidence=0.9 -->

---

## PoC: コンテナ内ファイルの編集と書き戻し

**id**: container-file-edit
**目的**: コンテナ内のファイルを Neovim のバッファで開き、保存操作でコンテナへ書き戻せることを確認する
**risk**: low
**blocker**: false
**対象リスク**: R-5

**スコープ**:

- 含む: `docker cp` による取得・書き戻し、`docker://<container>/<path>` 形式のバッファ名、保存フックでの書き戻し、失敗時に modified を保持できるか
- 含まない: ディレクトリ単位のコピー、バイナリファイルの扱い

**実装内容**:

1. コンテナ内のファイルを `docker cp` で一時領域へ取得し、指定した名前のバッファで開く
2. 保存操作を横取りするフック（`BufWriteCmd`）で `docker cp` による書き戻しを行う
3. 読み取り専用の場所へ書き戻して失敗させ、バッファの modified 状態が保たれることを確認する

**成功基準**:

- 編集内容がコンテナ内のファイルに反映される
- 書き戻し失敗時にバッファの変更が失われない

**失敗した場合の代替案**:

- 保存フックの横取りが困難なら、明示的なコマンド（`:DockerWrite` 相当）での書き戻しに切り替え、US-023 の受け入れ基準を見直す

**判断**: 成功 → 保存フック方式で実装 / 失敗 → 明示コマンド方式

**結果（2026-07-30、フェーズ 9 の実装後に実測）**: 成功。実コンテナに対し `docker cp` で取り出し、`docker://<container>/<path>` のバッファを `buftype=acwrite` で開き、`:write` で `BufWriteCmd` を発火させて書き戻せることを確認した（コンテナ内のファイルが実際に書き換わることまで確認）。バッファは `nvim_create_buf` で作ってから名前と種別を与える必要がある（`bufadd` + `bufload` だと種別が戻り横取りが効かない）。書き戻し失敗時に `modified` を保持することも確認済み。**明示コマンドへの切り替えは不要。**

<!-- POC_STATUS: id=container-file-edit, blocker=false, status=verified, confidence=0.95 -->

---

## PoC: 大量コンテナ時の描画性能

**id**: large-list-performance
**目的**: コンテナが多数ある環境での一覧の初回描画とライブ更新が実用的な速度に収まるかを確認し、NFR-4 の目標値を確定する
**risk**: low
**blocker**: false
**対象リスク**: R-6

**スコープ**:

- 含む: 200 件規模のコンテナでの一覧取得・整形・描画の所要時間計測、連続イベント時の再描画のデバウンス値の目安
- 含まない: リソース使用量（CPU / メモリ）取得時の負荷（今回のスコープ外。USER_STORIES.md の WN-008）

**実装内容**:

1. 停止状態のコンテナを 200 件作成する
2. 一覧の取得から描画までの所要時間を計測する
3. 短時間に多数のイベントを発生させ、デバウンスの有無で描画回数と体感がどう変わるか比較する

**成功基準**:

- 200 件の一覧が体感で待たされない時間（目安 500 ms 以内）で描画される
- 連続イベント下でカーソル操作が引っかからないデバウンス値が決まる

**失敗した場合の代替案**:

- 表示件数の上限を設けて残りをフィルタ（US-031）で辿らせる
- イベント受信時に全件再取得せず、対象行のみを差分更新する

**判断**: 成功 → 目標値を NFR-4 に確定 / 失敗 → 差分更新または表示上限を設計に含める

**結果（2026-07-29、フェーズ 4 の実装後に実測）**: 成功。macOS / Neovim 0.13.0 / docker 29.4.0 で、200 件の「解析 → ストア反映 → 描画」が 1.6〜2.2 ms、500 件で 4.5 ms、1000 件で 8.1 ms（おおむね線形）。`docker ps` の実行自体は 18.7〜54.0 ms なので、200 件の初回描画は合計 20〜60 ms に収まり、目標の 500 ms に対して十分な余裕がある。デバウンス幅は 100 ms に確定した（1 秒の目標に対し、再取得 20〜60 ms と描画 2 ms を加えても約 850 ms の余裕が残る）。**代替案（表示上限・差分更新）はいずれも不要。** 詳細は [DESIGN_DETAIL_APP.md の 11.3](DESIGN_DETAIL_APP.md#113-未確定要素) に記載。

<!-- POC_STATUS: id=large-list-performance, blocker=false, status=verified, confidence=0.95 -->

---

## 技術選定（PoC 結果で確定する項目）

| 項目 | 決定 | 根拠 |
| --- | --- | --- |
| 実装言語 | Lua（Neovim 0.10 以上） | k8s.nvim と同じ構成 |
| Docker との通信 | docker CLI のサブプロセス実行 | Engine API の直接利用は行わない（理由は DESIGN.md の「検討した代替案」に記載） |
| 一覧取得の出力形式 | フィールドごとに `{{json ...}}` で組み立てた NDJSON ＋ `--no-trunc` | PoC `docker-list-json-labels`（`--format json` は不採用） |
| compose ラベルの取得 | `{{json (.Label "com.docker.compose.project")}}` のキー名指し | PoC `docker-list-json-labels`（`Labels` 文字列の分割は不可） |
| ライブ更新 | `docker events --format '{{json .}}'` の購読（単一ジョブ） | PoC `docker-events-stream` |
| compose 情報の取得 | `docker compose config --format json` に一本化 | PoC `compose-project-detection`（`config --services` は順序が非決定的） |
| UI 基盤 | Neovim 標準 API のみ（Lua ライブラリ依存なし） | PoC `ui-foundation-choice` |
| テストフレームワーク | plenary.nvim（busted 互換、開発時依存） | k8s.nvim と同じ |

## PoC 結果

### docker-list-json-labels — verified (confidence 0.9)

- 検証日: 2026-07-29
- 観測した事実:
  - `--format json` の `Labels` は全ラベルをカンマ連結した 1 本の文字列。compose が必ず付与する `com.docker.compose.project.config_files` の値自体にカンマが入るため、カンマ分割すると `=` を持たない孤立断片が生じ、`com.example.desc=a,b=c` は値が `a` に欠落して phantom キー `b=c` が生成された
  - ラベル値に `,com.docker.compose.project=SPOOF_BEFORE` を仕込んだコンテナでは、分割結果に `com.docker.compose.project=` が 3 箇所（偽値・正解・偽値）現れ、**先頭一致でも末尾一致でも誤った値を掴む**（正解が中間にあり位置で判別できない）。Neovim Lua での実行でも判定 1 件が FAIL
  - フィールドごとに `{{json ...}}` でエスケープした NDJSON を組み立て、compose ラベルを `{{json (.Label "com.docker.compose.project")}}` で取る形式なら、全 11 コンテナで decode エラー 0・省略記号 0・compose 判定 4/4 一致。ダブルクォート・バックスラッシュ・改行・JSON 断片を含むラベル値でも 1 レコード 1 行が保たれた。単一実行 23 ms（`docker inspect` 併用は 60 ms）
  - 既定では ID=12 文字、Command=20 文字＋`…`、Mounts=14 文字＋`…` に切り詰められる。`--no-trunc` が必須
  - `.Size` を参照すると暗黙にサイズ計算が走るため、独自テンプレートでは参照しない
  - ラベル未設定時は `nil` ではなく空文字列 `""` が返る（非 compose コンテナの判定に使う）
  - `docker image ls` のみ `.Label` 非対応（`can't evaluate field Label`）で `Labels` フィールド自体が無い。volume ls / network ls は同一方式が使える
- 結論: 成功基準 3 点をすべて充足。当初の第一候補だった `--format json` は**採用しない**

### docker-events-stream — verified (confidence 0.85)

- 検証日: 2026-07-29
- 観測した事実:
  - 9 コマンドの送出に対し、対応する 11 種の（種別・動作・対象名）がすべて一致。受信 25 件・decode 失敗 0 件
  - 単一ジョブで container=11 / image=2 / network=8 / volume=4 のイベントを取得（種別ごとにジョブを分ける必要はない）
  - 行途中でのチャンク分割は通常の運用でも発生した（`on_stdout` 12 回中 2 回）。200 KB の単一イベント行も、未完了分を保持するバッファ方式で完全一致で復元できた
  - `jobstop` 後に `docker events` の子プロセスは残らなかった
  - ストリーム切断は `on_exit` で検知できた（SIGTERM=143 / SIGKILL=137）。ただし `jobstop` と外部 SIGTERM がともに 143 になるため、**停止が意図的かを示すフラグが必要**
  - `timeNano` は `vim.json.decode` で浮動小数点になり下位桁が落ちる。再購読の起点には秒精度の `time` を使う
  - volume イベントは `Actor.Attributes.name` が空で、ボリューム名は `Actor.ID` に入る
  - 切断中に発生したイベントは `docker events --since <直前の time>` で回収できたが、秒精度のため同一秒のイベントが重複する。再購読直後は全件再取得か ID による重複排除が要る
  - デーモン全体のイベントが流れるため（他プロセスの操作も混入する）、デバウンスが必須
- 結論: 成功基準 4 点をすべて充足。イベント駆動の更新機構を採用する
- 留保: docker デーモン自体の停止による切断は、利用者環境への影響を避けるため未実施。プロセスへのシグナル送出で代替検証した

### compose-project-detection — verified (confidence 0.92)

- 検証日: 2026-07-29
- 観測した事実:
  - `docker compose config --quiet` の終了コードは compose ファイルあり=0 / なし=1（stderr に `no configuration file provided: not found`）
  - `config --services` は 1 行 1 サービス名だが、**25 回の実行で並び順が 3 通りに揺れた**（一覧の行順が実行ごとに変わる）
  - `config --format json` の `.services` は 25/25 で同一順。1 回の実行で判定（終了コード）・プロジェクト名（`.name`）・サービス全件が同時に取れ、約 55 ms。`config` 系は `DOCKER_HOST` 不達でも動作するためデーモン停止中でも compose 判定ができる
  - `.name` はコンテナのラベル `com.docker.compose.project` と完全一致した（`name:` でディレクトリ名と異なる場合も含む）
  - 未起動のサービスも `config` から取得できる（`compose ps -a` には現れない）ため、状態 `none` を導出できる
  - サブディレクトリから実行すると親を遡上して compose ファイルを見つける
  - YAML が不正な compose ファイルも exit 1 を返すため、**終了コードだけでは「compose 外」と「compose が壊れている」を区別できない**。stderr での分岐が要る
  - `compose ls --format json` は単一の JSON 配列、`compose ps --format json` は NDJSON と形状が異なる。警告は stderr、JSON は stdout に分離されている
- 結論: 成功基準 4 点をすべて充足。CLI 委譲方式（BR-004）を採用し、取得は `config --format json` に一本化する
- 却下した代替案: 「カレントディレクトリ名をプロジェクト名とみなす」は `-p` 指定 / `COMPOSE_PROJECT_NAME` / `name:` ディレクティブ / サブディレクトリからの実行の 4 ケースで誤るため、縮退時のみの手段とする
- 未検証（スコープ外）: `profiles` / `include:` / 複数 `-f` 指定 / `COMPOSE_FILE` 環境変数

### ui-foundation-choice — verified (confidence 0.9)

- 検証日: 2026-07-29
- 観測した事実:
  - 同一の 22 項目のアサーションを両方式で満たす試作を書いたところ、UI 基盤層のコード量は標準 API=63 行 / nui.nvim=64 行で**差がなかった**（列幅計算・行整形・ハイライト位置算出の共通部 84 行は両者から除外して比較）
  - 実端末での描画は 1 文字も差異なし。24bit カラーのハイライトと winbar の装飾も同一。リサイズ追従も両者とも全ビューで成功
  - **nui.nvim は headless テストで Neovim ごと落ちた（10/10 で SIGSEGV）**。`nui/popup/border.lua` の `redraw` 呼び出しが引き金で、(1) headless の既定グリッドと異なる `columns`/`lines` を設定する、(2) メッセージ出力がある、(3) popup を mount する、の 3 条件が揃うと再現する。これはテストでレイアウトを決定的に検証する際の典型的な構成であり回避しにくい
  - k8s.nvim の window 実装 589 行のうち 399 行は「3 つのポップアップを 1 つの外枠に見せる」ための境界文字の割り振りと同期処理だった。標準 API では外枠とタイトルを `nvim_open_win` の `border` / `title` が、カラムヘッダを `winbar` が担うため、この 399 行がまるごと不要になる
  - ヘッダーをバッファに入れないため、カーソル行とデータ行の添字が 1 対 1 になり行番号の補正が不要
  - ビューの重ね合わせは `zindex` で実現でき、上層を閉じると下層の内容とカーソル位置がそのまま残ることを確認した
- 結論: **Neovim 標準 API のみを採用する**。nui.nvim はコード量の利点が無く、テスト時のクラッシュという明確な不利益がある
- 再検討の条件: compose のツリー表示や複合レイアウトが必要になった時点で再評価する。入力・選択 UI は `vim.ui.input` / `vim.ui.select` を使い、利用者の既存設定に乗せる

### 未検証のまま残す PoC（blocker=false）

`container-file-edit` と `large-list-performance` は実装方針を左右しないため、詳細設計に `POC_NEEDED` マーカーとして転記し、実装フェーズで検証する。
