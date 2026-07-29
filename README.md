# docker.nvim

Neovim から Docker を操作するプラグイン。コンテナ・イメージ・ボリューム・ネットワークに加えて、**docker compose のサービスをプロジェクト単位で一覧・操作できる**。

一覧は `docker events` を購読して自動で更新される。別のターミナルでコンテナを起動・停止しても、Neovim 側の一覧が 1 秒以内に追従する。

```
NAME                     IMAGE            STATUS         PORTS                   PROJECT  SERVICE
shop-web-1               nginx:alpine     Up 5 days      0.0.0.0:8080->80/tcp    shop     web
shop-db-1                postgres:16      Up 5 days                              shop     db
my-standalone-container  alpine:3.20      Exited (0) 3h
```

## 前提

- Neovim 0.10 以上（`vim.system` を使う）
- `docker` コマンドが PATH 上にあること
- compose の機能には `docker compose` サブコマンドが必要（無くてもそれ以外は動く）
- 対応プラットフォームは macOS と Linux

ランタイムのプラグイン依存はない。テスト実行にのみ [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) を使う。

## インストール

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "skanehira/docker.nvim",
  cmd = "Docker",
  opts = {},
}
```

`opts` を渡すと `require("docker").setup(opts)` が呼ばれる。設定を変えないなら `opts = {}` でよい。

## 使い方

| コマンド | 内容 |
| --- | --- |
| `:Docker containers` | コンテナ一覧 |
| `:Docker images` | イメージ一覧 |
| `:Docker volumes` | ボリューム一覧 |
| `:Docker networks` | ネットワーク一覧 |
| `:Docker services` | compose サービス一覧（カレントディレクトリの compose プロジェクト） |

`<Plug>(docker-containers)` のようなマッピングも公開しているので、好きなキーに割り当てられる。

```lua
vim.keymap.set("n", "<leader>dc", "<Plug>(docker-containers)")
```

## キーマップ

一覧はフロートウィンドウで開き、キーはそのバッファにだけ設定される。他のバッファの操作を奪わない。

**全一覧ビュー共通**

| キー | 操作 |
| --- | --- |
| `<CR>` | 詳細（`docker inspect`）を表示 |
| `R` | 一覧を取り直す（切れていたイベント購読も再開する） |
| `<Tab>` | 別のリソースの一覧へ切り替える |
| `<C-f>` | 表示中の値で絞り込む（`/` は Neovim 本来の検索のまま） |
| `?` | そのビューで有効なキーの一覧 |
| `q` | 閉じる |

**コンテナ一覧**

| キー | 操作 | | キー | 操作 |
| --- | --- | --- | --- | --- |
| `u` | 起動 | | `t` | ログを追う |
| `d` | 停止 | | `a` | シェルを開く |
| `r` | 再起動 | | `e` | コマンドを実行 |
| `<C-k>` | 強制終了 | | `E` | コンテナ内のファイルを編集 |
| `p` / `P` | 一時停止 / 解除 | | `ct` / `cf` | ホストへ / ホストから コピー |
| `D` | 削除（確認あり） | | `<C-o>` | 公開ポートをブラウザで開く |
| `gd` | このコンテナのイメージへ | | | |

**イメージ一覧**: `r` 使い捨てコンテナでシェル / `D` 削除 / `gd` このイメージを使うコンテナへ

**ボリューム・ネットワーク一覧**: `D` 削除

**compose サービス一覧**

| キー | 操作 |
| --- | --- |
| `u` / `d` / `r` | サービスの起動 / 停止 / 再起動 |
| `t` | サービスのログを追う |
| `U` | プロジェクト全体を起動 |
| `D` | プロジェクト全体を破棄（確認あり） |
| `gd` | このサービスのコンテナへ |

Visual モードで範囲を選んでから `D` を押すと、まとめて削除できる。

一覧では `<C-d>` / `<C-u>` / `<C-b>` が Neovim 本来のスクロールとして使える（`<C-f>` だけは絞り込みに割り当てている）。

## 設定

```lua
require("docker").setup({
  -- デバッグ出力（実行した docker コマンドと終了コード）
  debug = false,

  -- キーはビュー種別ごとに差し替えられる。false を渡すとその割り当てを外す。
  keymaps = {
    common = { close = "<Esc>" },
    container_list = {
      start = "s",
      delete = false,
    },
  },
})
```

ビュー種別は `common` / `container_list` / `image_list` / `volume_list` / `network_list` / `service_list`。同じキーをビューごとに別の操作へ割り当てられる（コンテナ一覧の `r` は再起動、イメージ一覧の `r` は使い捨て実行）。

未知のビュー種別やアクション名を書いた場合は、その項目だけ無視して警告する。

## 設計上の約束

- 削除に `-f` は付けない。実行中コンテナの削除は docker に拒否させ、そのエラーをそのまま見せる
- 前提を満たさない操作（停止中のコンテナへの `<C-k>` など）は docker を呼ばずに警告する
- 同じ対象への同じ操作は同時に 1 つまで。実行中の行には `(実行中)` が付く
- 起動した子プロセスは台帳で追跡し、`:qa` で必ず止める

## 開発

```bash
make check     # lint / format / typecheck / plugin-check / test
make test      # 単体・結合テスト
make test-e2e  # 実 docker に対する通しシナリオ（docker が必要）
```

`make test-file FILE=path/to/foo_spec.lua` で 1 ファイルだけ実行できる。

## ライセンス

MIT
