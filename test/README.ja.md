# テスト

*[English](README.md) | 日本語*

rcd プラグインのテスト群。**どこまで自動化できるか**で分類してあり、それは各層が
何を検証できるかに従う。決定的な機構（unit の起動ロジック、skill/plugin 定義、
systemd 配線）は**スタブ `claude`**（`test/stub-claude`）で検証し、認証もネットも
不要なので完全自動。**実 Claude** が `SKILL.md` を辿るか、プラグインがロードされるか、
`claude remote-control` のライブ実行時挙動が動くか、は実 Claude が要るため手で実行する。

実 Claude を使う層はすべて、専用 `HOME` を持つ**使い捨ての privileged systemd
Docker コンテナ**内で完結し、ホストの unit・skill・インスタンスには触れない。

## 概観

| 層 | 自動化 | 検証する内容 |
|---|---|---|
| `lint` | 全自動（CI） | skill/plugin の**定義**: frontmatter、`allowed-tools` の網羅、unit のインラインシェルが解析可能で `RCD_INSTANCE` を配線、同梱パスが `${CLAUDE_PLUGIN_ROOT}` 形式。 |
| `logic` | 全自動（CI） | unit の**起動ロジック**を単体で: worktree か same-dir、`--name` / セッション名 prefix、未初期化・claude 欠落ガード。 |
| `service` | 全自動（要 Docker） | unit が **`systemctl --user` サービスとして起動**: 基底プロセスの引数と `RCD_INSTANCE`、same-dir と worktree。 |
| `skill` | 半自動 | 実 Claude が **`SKILL.md` を辿る**: プラグインのロード、`/rcd` 解決、`init` が設定記録＋unit 導入、`start` が dir 作成＋unit enable、不正名の拒否。 |
| `live` | 手動 | スタブでは届かない **`claude remote-control` のライブ実行時挙動**: on-demand/worktree セッションへの `RCD_INSTANCE` 継承、セッション名形式、ライブでの SELF 拒否・typed confirm。 |

`skill` と `live` は受け入れハーネス（`test/acceptance/`）の2モード。1回の実行が
`skill` 検査を自動で行い、`live` 検査は手で行う分として残す。

## 全自動

hermetic（スタブ `claude`）。毎回の変更で実行する継続的な安全網。

```sh
./test/run.sh        # lint + logic — Docker・ネット不要、CI-safe
./test/service.sh    # service — systemd Docker コンテナをビルド（要 Docker）
```

`lint` は外部リンタ `skill-tools` / `claudelint` がある場合（または
`RCD_LINT_EXTERNAL=1`）に併せて走る。npm を取得するためオプトイン。

## 半自動 — `skill`

`setup-token`（inference スコープ）で足りる。

```sh
claude setup-token                 # Claude サブスクリプションが必要
export CLAUDE_CODE_OAUTH_TOKEN=<token>
./test/acceptance/run-acceptance.sh
```

実行後はコンテナ `rcd-acceptance-run` を**起動したまま**残し、`live` が再利用できる
ようにする。teardown は完全に終えるときだけ — 続けて `live` を行うならスキップする
（`live` が同じ teardown で締める）:

```sh
./test/acceptance/run-acceptance.sh --teardown
```

一部のモデル判断項目（例: 不正名をどう拒否するか）は自動採点せず読んで確認する用に
出力される。

**走らせるとき:** `SKILL.md` の文面（手順・名前ルール・同梱ファイル参照）が変わった、
梱包（`plugin.json` / `marketplace.json`、構成、skill 名、unit 位置）が変わった、
`claude` CLI をメジャー級／挙動に影響する版へ更新した。

## 手動 — `live`

**full `claude auth login`**（`setup-token` では `claude remote-control` を起動
できない）と claude.ai/code アプリが必要。

`docker exec` は**ホスト側シェル**、つまり `run-acceptance.sh` を実行したのと同じ
ターミナルで実行する（同スクリプトが `rcd-acceptance-run` を起動したまま残す）。各
コマンドはコンテナ内でユーザ `rcd`（uid 1000）として実行されるので、自分でコンテナに
入る必要はない。先に `skill` を1回実行し、ここを終えるまで teardown しないこと。

1. full スコープのトークンでログイン（表示される URL / デバイスコードに従う）:

   ```sh
   docker exec -it -u rcd rcd-acceptance-run claude auth login
   ```

2. ディレクトリが git 最上位のインスタンスを起動し（on-demand が worktree になる）、
   基底セッションが立ち上がったことを確認する:

   ```sh
   docker exec -it -u rcd rcd-acceptance-run bash -lc '
     export XDG_RUNTIME_DIR=/run/user/1000
     mkdir -p ~/rcdtest-root/rcdtest-live && git -C ~/rcdtest-root/rcdtest-live init -q
     systemctl --user enable --now claude-remote-control@rcdtest-live.service
     sleep 3; systemctl --user is-active claude-remote-control@rcdtest-live.service'
   ```

   `active` を期待。`activating`（再起動ループ）のままならログインが効いていないので
   手順1をやり直す。

3. claude.ai/code で `rcdtest-host-rcdtest-live-base` の**新規**セッションを開き
   （on-demand worktree セッションが spawn される）、その中で確認する:

   - `echo "$RCD_INSTANCE"` が `rcdtest-live` を表示 — on-demand/worktree セッション
     に env が継承されている（self 検出の前提）。空なら欠陥。
   - セッション名が `rcdtest-host-rcdtest-live-<auto>`（`-` 区切り）であること。
   - `/rcd stop rcdtest-live` と `/rcd destroy rcdtest-live` が両方**拒否**される
     こと（自分が SELF）。`/rcd restart-all` は SELF を後回し（detached 再起動）。

4. 後片付けし、claude.ai/code に残った `rcdtest-host-*` セッションを削除する:

   ```sh
   ./test/acceptance/run-acceptance.sh --teardown
   ```

**走らせるとき:** ベースライン確立、unit の識別/命名/spawn 配線（`RCD_INSTANCE`、
`--name`、セッション名 prefix、`--spawn`）が変わった、または `claude` / claude.ai が
remote-control の env 継承やセッション名描画を変えた疑いがあるとき。

## 補足

- `skill` と `live` は設計上、手動 — CI に組み込まない。
- 発見は昇格させる: `skill` / `live` で最初に捕えた失敗は、可能なら `lint` / `logic`
  の検査に移し、手動の面を縮小する。
