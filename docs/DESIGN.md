<!-- product-mode: cli -->

# docker.nvim 概要設計

- 種別: 概要設計書
- 対象: docker.nvim
- 作成日: 2026-07-29
- 詳細: [DESIGN_DETAIL_APP.md](DESIGN_DETAIL_APP.md)（アプリ実装） / [DESIGN_DETAIL_INFRA.md](DESIGN_DETAIL_INFRA.md)（CI・配布・運用）
- 前提: [USER_STORIES.md](USER_STORIES.md) / [USECASES.md](USECASES.md) / [FEASIBILITY.md](FEASIBILITY.md) / [GLOSSARY.md](GLOSSARY.md) / [DOMAIN_MODEL.md](DOMAIN_MODEL.md)

## 目次

- [1. 共通](#1-共通)
  - [1.1 目的とスコープ](#11-目的とスコープ)
  - [1.2 機能要件](#12-機能要件)
  - [1.3 ゴール](#13-ゴール)
  - [1.4 全体構成図](#14-全体構成図)
  - [1.5 技術スタック](#15-技術スタック)
  - [1.6 検討した代替案](#16-検討した代替案)
  - [1.7 制約と前提](#17-制約と前提)
  - [1.8 未解決の論点](#18-未解決の論点-open-issues)
- [2. アプリケーション概要](#2-アプリケーション概要)
- [3. インフラ概要](#3-インフラ概要)

---

## 1. 共通

### 1.1 目的とスコープ

**目的**: Neovim から離れずに Docker のリソースを閲覧・操作できるようにし、`docker ps` や `docker compose logs` のためにターミナルを往復する手間をなくす。

**スコープに含むもの**: コンテナ・イメージ・ボリューム・ネットワークの一覧と操作、存在するすべての compose プロジェクトを統合したサービス一覧と、そのサービス／プロジェクト操作、コンテナがどの compose プロジェクトのどのサービス由来かの可視化、`docker events` によるライブ更新。

**スコープに含まないもの（非ゴール）**:

| 非ゴール | 理由 |
| --- | --- |
| Docker Hub のイメージ検索・pull | 利用頻度が低く、代替（`docker pull`）が容易 |
| compose ファイルの場所が分からないプロジェクトの起動（`u` / `U`） | 起動には compose ファイルの定義そのものが要り、場所の推測は誤った定義での起動につながる。停止・再起動・破棄・ログはプロジェクト名の名指しで実行できる（BR-024） |
| Docker Swarm / Kubernetes 連携 | k8s.nvim の領域 |
| イメージのビルド（`docker build`） | ビルドコンテキスト指定の UI が必要でスコープが膨らむ |
| volume / network の作成 | compose か docker CLI で行うのが通常 |
| `:checkhealth` による自己診断 | 環境問題は起動時のメッセージで切り分けられる |
| `:Docker` の引数なし起動とサブコマンド補完 | 今回はサブコマンドの明示指定のみ対応する |

### 1.2 機能要件

**MUST**（[USER_STORIES.md](USER_STORIES.md) の US-001〜US-015）

- コンテナとイメージの一覧表示、および compose サービスの一覧表示
- コンテナのライフサイクル操作（start / stop / restart / kill）と削除
- コンテナのログ追従・シェル起動・コマンド実行・詳細表示
- イメージの一覧と削除
- compose サービスの up / stop / restart / ログ、プロジェクトの up -d / down
- `docker events` によるライブ更新と `R` による手動再取得
- docker 未検出・デーモン未起動・権限不足の区別されたメッセージ
- UI をブロックしない非同期実行、ヘルプ表示

**NICE to have**（US-016〜US-031）

キーマップのカスタマイズ、使い捨てコンテナ実行、ボリューム／ネットワークの一覧・詳細・削除、イメージの詳細表示、公開ポートのブラウザ起動、ファイルのコピーと編集、ビュー間切替、進行表示と二重実行防止、全ビューのライブ更新、ドリルダウン、一括削除、pause / unpause、絞り込み。

扱うリソース種別は container / image / volume / network / service の 5 種だが、このうちボリュームとネットワークは Must ではない（US-018 / US-019 は Should）。ただし実装順序としては、リソース定義の追加のみで済むためコンテナ・イメージと同じフェーズで扱う（[TODO.md](TODO.md) のフェーズ 8）。

### 1.3 ゴール

- G1: `:Docker containers` を実行すると、停止中を含む全コンテナが NAME / IMAGE / STATUS / PORTS / PROJECT / SERVICE のカラムで表示され、compose 由来のコンテナには PROJECT / SERVICE の値が入る
- G2: コンテナ一覧で `u` / `d` / `r` / `<C-k>` を押すと対象コンテナの状態が変化し、一覧の STATUS 列に反映される（`p` / `P` による一時停止・再開は Could 扱いの US-030 のため、このゴールには含めない）
- G3: `D` を押すと確認プロンプトが出て、`y` のときのみ削除される。`y` 以外では docker に削除要求が送られない
- G4: `t` / `a` / `e` でターミナルバッファが開き、そのバッファを閉じると対応する docker の子プロセスが 0 件になる
- G5: `<CR>` で inspect の JSON が表示され、`q` で直前の一覧に戻ってカーソル位置が復元される
- G6: `:Docker images` / `:Docker volumes` / `:Docker networks` がそれぞれ一覧表示され、`D` の確認を経て削除できる
- G7: compose プロジェクトの外のディレクトリで `:Docker services` を実行しても、存在するすべての compose プロジェクトのサービスが PROJECT 列付きで並び、コンテナが起動していないサービスが状態 `none` として表示される
- G8: サービス一覧で `u` / `d` / `r` / `t` がサービス単位に、`U` / `D` がプロジェクト単位に作用し、いずれも行のプロジェクトを `-p` で名指しして実行される（他のプロジェクトを巻き込まない）
- G9: 一覧を開いている状態で別プロセスがコンテナを起動・停止すると、1 秒以内に一覧の該当行が更新される
- G10: `R` を押すと一覧が再取得され、イベント購読が切断されていれば再開される
- G11: docker 未検出・デーモン未起動・ソケット権限不足・`docker compose` サブコマンド不在の 4 状況が、それぞれ区別できるメッセージで通知される
- G12: `?` でそのビューの有効なキー一覧が表示され、`setup()` で変更したキーが反映される。一覧ビュー以外のバッファではプラグインのキーが作用しない
- G13: 一覧・ターミナルを開いたまま `:qa` で Neovim を終了すると、プラグインが起動した子プロセスが 0 件になる
- G_E2E: MVP の全ユースケースが、headless の Neovim から実際の docker に対して通しで実行でき、各ステップの結果（一覧の内容・状態変化・プロセスの残留有無）が assert される

検証手順は [DESIGN_DETAIL_APP.md の検証手順](DESIGN_DETAIL_APP.md#9-検証手順) に 1 対 1 で対応させる。

### 1.4 全体構成図

```mermaid
flowchart TB
    User[Neovim 開発者]

    subgraph nvim[Neovim プロセス]
        subgraph plugin[docker.nvim]
            Cmd[":Docker サブコマンド<br/>plugin/docker.lua"]
            Ctrl["コントローラ<br/>init.lua"]
            Config["設定・キーマップ<br/>config.lua"]

            subgraph handlers[ハンドラ層]
                Actions[アクション実行]
                Render[描画マネージャ]
                Lifecycle[ビューのライフサイクル]
                Ops[実行中操作の台帳]
                Jobs[ジョブ台帳]
            end

            subgraph domain[ドメイン層]
                Store[リソースストア]
                Registry[リソース定義]
                Compose["compose サービス一覧の組み立て"]
            end

            subgraph views[ビュー層]
                List[一覧ビュー]
                Inspect[詳細ビュー]
                Help[ヘルプビュー]
                Term[ターミナルビュー]
            end

            subgraph adapter[アダプタ層]
                CLI[docker CLI アダプタ]
                Events[イベント購読]
                ComposeCLI[compose CLI アダプタ]
            end
        end
    end

    Docker[(docker デーモン)]

    User -->|コマンド・キー操作| Cmd
    Cmd --> Ctrl
    Config --> Ctrl
    Ctrl --> Actions
    Ctrl --> Lifecycle
    Actions --> Ops
    Actions --> CLI
    Actions --> ComposeCLI
    Ops --> Jobs
    Lifecycle --> views
    Store -->|状態変化の通知| Render
    Render --> views
    Registry --> views
    Registry --> CLI
    Registry --> Compose
    Compose --> CLI
    Compose --> ComposeCLI
    Compose --> Store
    CLI -->|docker コマンド| Docker
    ComposeCLI -->|docker compose| Docker
    Docker -->|イベントストリーム| Events
    Events --> Store
    Events --> Jobs
    Term -->|ターミナルジョブ| Docker
    Term --> Jobs
    views -->|表示| User
```

### 1.5 技術スタック

| 区分 | 技術 | 選定理由 |
| --- | --- | --- |
| 実装言語 | Lua（Neovim 0.10 以上） | Neovim の標準実行環境。外部ランタイムを要求しない |
| Docker との通信 | `docker` CLI のサブプロセス実行 | Engine API を直接叩くと HTTP と Unix ソケットを自前実装することになる。CLI なら DOCKER_HOST・docker context・SSH 越し接続の解決を CLI に任せられる |
| 一覧の取得形式 | フィールドごとに `{{json ...}}` で組み立てた NDJSON（`--no-trunc` 付き） | PoC で `--format json` の `Labels` が解析不能と判明したため（[1.6](#16-検討した代替案)） |
| compose 情報の取得 | 4 経路の組み合わせ: `docker compose ls -a --format json`（プロジェクトの列挙）＋ コンテナの compose ラベル（サービスの実体と compose ファイルの所在）＋ カレントディレクトリでの `docker compose config --format json`（未起動プロジェクトの合流。BR-003）＋ `docker compose -p <project> config --format json`（各プロジェクトのサービス定義の全件） | 前 2 者はコンテナのラベル由来のため、compose プロジェクトの外から実行しても全プロジェクトを列挙できる。一度も起動していないプロジェクトはラベルに現れないので、3 番目でのみ拾える。`config` は未起動のサービスも含めて全件が取れ、`-p` で名指しすればディレクトリ名から決まる既定名とのずれで取り違えない |
| ライブ更新 | `docker events --format '{{json .}}'` の単一ジョブ購読 | 1 本のストリームで container / image / volume / network すべてのイベントが取れることを PoC で確認 |
| UI 基盤 | Neovim 標準 API（`nvim_open_win` の `border` / `title`、`winbar`、extmark、`zindex`） | PoC で nui.nvim と比較し、コード量に差が無く（63 行 対 64 行）、nui は headless テストで Neovim が落ちるため |
| 非同期実行 | `vim.system`（単発）/ `vim.fn.jobstart`（ストリーム・ターミナル） | Neovim 0.10 以降の標準機能。追加依存が不要 |
| 入力・選択 UI | `vim.ui.input` / `vim.ui.select` | 利用者が導入済みの UI プラグインにそのまま乗る |
| テスト | plenary.nvim（busted 互換） | Neovim プラグインの事実上の標準。開発時のみの依存 |
| CI | GitHub Actions | リポジトリと同居し追加コストが無い |
| Lint / 整形 / 型検査 | luacheck / stylua / lua-language-server | k8s.nvim で運用実績がある組み合わせ |

### 1.6 検討した代替案

後から変更するコストが高い決定のみを挙げる。

| 決定事項 | 採用案 | 却下案 | 却下理由 |
| --- | --- | --- | --- |
| Docker との通信手段 | docker CLI のサブプロセス実行 | Docker Engine API を Unix ソケットで直接叩く | HTTP のチャンク応答処理を Lua で自前実装することになる。DOCKER_HOST・docker context・SSH 越し接続・TLS の解決も自前になり、対応環境が CLI より狭まる。denops-docker.vim は Deno のソケット API があったため API を選べたが、Lua には同等の土台が無い |
| 一覧の出力形式 | フィールドごとに `{{json ...}}` を並べた NDJSON | `docker ps --format json` | `Labels` が全ラベルをカンマ連結した 1 本の文字列で、compose が付与する `com.docker.compose.project.config_files` の値自体にカンマを含む。さらにラベル値に `,com.docker.compose.project=偽値` を仕込むと同名キーが複数現れ、先頭一致でも末尾一致でも誤った値を掴むことを実測した（[FEASIBILITY.md の PoC 結果](FEASIBILITY.md#docker-list-json-labels--verified-confidence-09)） |
| サービス一覧の対象範囲 | `docker compose ls -a` の列挙とコンテナの compose ラベル（`com.docker.compose.project` / 同 `.project.working_dir`）から、存在する全プロジェクトを逆算する | カレントディレクトリで `docker compose config` を 1 回実行し、そのプロジェクトだけを扱う | compose ディレクトリの外では一覧が空になり、`:Docker services` を開く前に `cd` を強いる。ラベル由来なら停止中のプロジェクトも含めて列挙でき、compose ファイルの所在まで同時に分かる |
| compose サービス定義の取得 | `docker compose -p <project> config --format json` | `docker compose config --services` | 25 回の実行で出力順が 3 通りに揺れ、一覧の行順が実行のたびに変わる |
| compose プロジェクト名の解決 | `compose ls` の `Name` とコンテナのラベル `com.docker.compose.project`（操作は `-p <project>` で名指しする） | カレントディレクトリ名をプロジェクト名とみなす（lazydocker 方式） | `-p` 指定・`COMPOSE_PROJECT_NAME`・`name:` ディレクティブ・サブディレクトリからの実行の 4 ケースで誤る |
| UI 基盤 | Neovim 標準 API のみ | nui.nvim を唯一のランタイム依存として採用（k8s.nvim 方式） | 同等のビューを実装したコード量が 63 行 対 64 行で差が無く、依存を増やす利点が無い。さらに nui は headless テストで 10 回中 10 回 Neovim を SIGSEGV させ、レイアウトを決定的に検証するテストが書けない |
| ライブ更新の方式 | `docker events` の購読 | 一定間隔のポーリング（`docker ps` の再実行） | ポーリングは反映が遅れ、間隔を詰めるとデーモンへの負荷が上がる。イベント購読は PoC で取りこぼし 0 件を確認済み。ただし切断時の縮退先としてポーリングではなく手動更新（`R`）を用意する |

### 1.7 制約と前提

- Neovim 0.10 以上（`vim.system` を使う）。CI では 0.10 と stable の 2 系統で検証する
- `docker` コマンドが PATH 上にあること。compose 機能には `docker compose` サブコマンドが必要（無い場合も compose 以外の機能は動作する）
- ランタイムの Lua ライブラリ依存は持たない
- 対象プラットフォームは macOS と Linux。Windows は検証対象外とする
- サービス一覧は存在するすべての compose プロジェクトを対象とし、各操作は行のプロジェクトを `-p` で名指しして実行する。カレントディレクトリは一覧を開いた時点で固定し、そのディレクトリの compose プロジェクト（未起動でラベルに現れないもの）を一覧へ合流させることと、そのプロジェクトの compose ファイルの場所を決めることに使う（BR-003）
- compose の定義を引けないプロジェクト（compose ファイルの場所が分からない、または場所で `config` に失敗した）は、コンテナが実在するサービスのみ一覧に出す。起動（`u` / `U`）は場所が分からないときだけ docker を呼ばずに警告し、停止・再起動・破棄・ログはプロジェクト名の名指しで実行する（BR-024）

### 1.8 未解決の論点 (Open Issues)

なし。

決定済み（インタビューで解消した論点）:

- リソース使用量表示（US-032）は今回のスコープから外し、後回しにする。[USER_STORIES.md](USER_STORIES.md) の Won't（WN-008）へ移した
- 一覧の絞り込み（US-031）のキーは `<C-f>` とする（k8s.nvim と同じ割り当て）。`/` を潰さないため、そのバッファで Neovim 本来の検索が引き続き使える

- 一覧ビューの表示形態は**フロートウィンドウ**とする。詳細・ヘルプの重ね合わせを `zindex` で自然に扱えるため
- ビュー切替は `<Tab>`（切替先を選択メニューから選ぶ）、ドリルダウンは `gd` とする
- 実装は Must（US-001〜US-015）を 1 周目として通しで仕上げてから Should 以降に進む。ただし Must と同じモジュールに手を入れる Should（設定合成・操作の排他・単一バッファ化・ボリューム／ネットワーク・イメージ詳細）は、二度手間を避けるため同じフェーズに含める（対応は [TODO.md](TODO.md) の概要の表を参照）

---

## 2. アプリケーション概要

詳細は [DESIGN_DETAIL_APP.md](DESIGN_DETAIL_APP.md) を参照。

### 2.1 主要コンポーネントと責務

| コンポーネント | 責務 | 依存先 |
| --- | --- | --- |
| コマンド定義（`plugin/`） | `:Docker <サブコマンド>` の定義とコントローラへの委譲 | コントローラ |
| コントローラ（`init.lua`） | `setup()` の受け付け、ビューを開く・閉じる、キーからアクションへのディスパッチ | 設定・ハンドラ層・ビュー層 |
| 設定（`config.lua`） | デフォルト設定と利用者設定の合成、キーマップ定義の保持と検証 | なし |
| リソース定義（`resources/`） | リソース種別ごとの取得コマンド・カラム・行への変換・状態の取り出しを宣言的に保持。単一コマンドで取れない compose サービス一覧のみ、複数の取得結果の突き合わせも担う | なし（compose サービス一覧の組み立てのみアダプタ層） |
| リソースストア（`state/`） | 観測したリソースの保持、更新の通知（Observer） | なし |
| ハンドラ層（`handlers/`） | アクションの実行、描画の集約とデバウンス、ビューのライフサイクル、実行中操作とジョブの台帳 | ドメイン層・アダプタ層・ビュー層 |
| ビュー層（`views/`, `ui/`） | ビュー状態のバッファへの投影、ウィンドウとキーマップの管理 | リソース定義・UI ヘルパ |
| アダプタ層（`adapters/`） | docker / docker compose CLI の実行、出力の解析、イベントストリームの購読 | なし（外界との境界） |

### 2.2 レイヤーと依存の方向

```
plugin/ → init.lua → handlers/ → { state/, resources/, adapters/, views/ }
                                    resources/ → adapters/（compose サービス一覧の組み立てのみ）
                                    views/ → ui/, resources/
```

- 依存は上から下への一方向。`state/` と `adapters/` はビューを知らない
- `resources/` は原則として外界に触れないが、compose サービス一覧だけは 3 種の取得結果を突き合わせる多段の非同期処理になるためアダプタ層を呼ぶ。呼ぶのはこの組み立てモジュールに限り、宣言的定義（`resources/registry.lua`）からは分離する
- 外界（docker コマンドの実行・時刻・ジョブ起動）はすべてアダプタ層に閉じ込め、テストでは差し替えられるようにする（[設計原則](../../../.claude/rules/core/design.md) の「外界は DI」）
- リソース種別の追加は「リソース定義の追加 ＋ キーマップ定義の追加」で完結させ、ビューやハンドラの分岐を増やさない

### 2.3 主要エンティティ

[DOMAIN_MODEL.md](DOMAIN_MODEL.md) で定義した集約とエンティティを実装に対応させる。フィールドの詳細は [DESIGN_DETAIL_APP.md](DESIGN_DETAIL_APP.md#4-データ構造) を参照。

| エンティティ | 識別子 | 保持場所 |
| --- | --- | --- |
| コンテナ / イメージ / ボリューム / ネットワーク | ID または名前 | リソースストア |
| compose サービス | プロジェクト名 ＋ サービス名（`<プロジェクト名>/<サービス名>`） | リソースストア |
| ビュー | ビュー種別 | ビュースタック |
| 実行中操作 | 対象 ID ＋ 操作名 | 実行中操作の台帳 |

### 2.4 非機能要件（アプリ側）

| 項目 | 目標 |
| --- | --- |
| 応答性 | docker コマンドの実行中に Neovim の入力がブロックされない（同期実行を使わない） |
| 更新の反映 | イベント受信から画面反映まで 1 秒以内。連続イベントはデバウンスで 1 回にまとめる |
| 一覧の描画 | コンテナ 200 件で初回描画 500 ms 以内（PoC `large-list-performance` で確定する） |
| プロセス管理 | ビュー破棄時と Neovim 終了時に、プラグインが起動した子プロセスを 0 件にする |
| 依存 | ランタイムの Lua ライブラリ依存を持たない |

### 2.5 テスト戦略（方針）

- **単体・結合テスト中心**: アダプタ層を差し替えて docker 無しで実行できるようにし、リソース定義の変換・ストアの更新・ビューの描画内容・キーからアクションへの解決を検証する
- **E2E は G_E2E の 1 本に絞る**: 実際の docker に対する通し確認は G_E2E のスクリプトのみとし、個別機能は単体・結合で担保する
- テストは実装ファイルと同じディレクトリに `*_spec.lua` として置く（コロケーション）
- カバレッジの数値目標は置かず、[USER_STORIES.md](USER_STORIES.md) の受け入れ基準を単体・結合テストで網羅することを基準とする

---

## 3. インフラ概要

このプロダクトは Neovim プラグインであり、サーバー・クラウドリソース・デプロイ先を持たない。インフラ章の対象は CI と配布のみとなる。詳細は [DESIGN_DETAIL_INFRA.md](DESIGN_DETAIL_INFRA.md) を参照。

### 3.1 実行環境と配布

| 項目 | 内容 |
| --- | --- |
| 実行環境 | 利用者の Neovim（0.10 以上）。サーバー側の実行環境は無い |
| 配布 | GitHub リポジトリをプラグインマネージャ（lazy.nvim 等）が直接取得する。パッケージレジストリへの公開は行わない |
| 環境の面数 | 1（利用者のローカル環境のみ）。ステージング・本番の区別は無い |

### 3.2 CI 方針

GitHub Actions で、プッシュとプルリクエストをトリガーに次を実行する。

| ジョブ | 内容 |
| --- | --- |
| test | plenary.nvim による単体・結合テスト。Neovim 0.10 と stable のマトリクス |
| lint | luacheck |
| format | stylua の差分チェック |
| typecheck | lua-language-server による静的検査 |
| e2e | 実際の docker に対する G_E2E の通し確認（Linux ランナー同梱の docker を使用） |

G_E2E は実際の docker デーモンを必要とするため、CI では Linux ランナーの docker を使って実行する。詳細は [DESIGN_DETAIL_INFRA.md](DESIGN_DETAIL_INFRA.md#3-cicd-パイプライン) を参照。

### 3.3 非機能要件（インフラ側）

| 項目 | 内容 |
| --- | --- |
| 可用性 | 該当なし（常時稼働するサービスを持たないため） |
| スケーラビリティ | 該当なし（同上） |
| 監視 | 該当なし。障害の検知は利用者からの Issue による |
| シークレット管理 | 該当なし（CI で外部サービスの認証情報を使わないため） |
