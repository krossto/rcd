# テスト

*[English](README.md) | 日本語*

rcd プラグインのテスト群。**どこまで自動化できるか**で分類してあり、それは
**各層が何を検証できるか**を反映している。

検証対象は2種類あり、必要な仕組みが異なる:

1. **決定的な機構** — unit の起動ロジック、skill/plugin の定義、systemd 配線。
   **スタブ `claude`**（`test/stub-claude`）で検証するため、実 Claude・認証・
   ネットワークは不要で、完全に自動化できる。
2. **実 Claude の挙動** — 実際の Claude が `SKILL.md` を辿るか、プラグインが
   ロードされ `/rcd` が解決するか、そして `claude remote-control` のライブ実行
   時挙動。実 Claude（最深部の確認ではログイン済みアカウントとアプリも）が要る
   ため CI には載せられず、手で実行する。

実 Claude を使う層はすべて、専用 `HOME` を持つ**使い捨ての privileged systemd
Docker コンテナ**内で完結する。ホストの unit・skill・稼働インスタンスには一切
触れない。

## 概観

| 層 | 自動化 | 検証する内容 | 走らせるとき |
|---|---|---|---|
| `lint` | **全自動**（CI） | skill/plugin の**定義**の健全性: frontmatter、`allowed-tools` が使用コマンドを網羅、unit のインラインシェルが解析可能、`RCD_INSTANCE` 配線、同梱パスが置換可能な `${CLAUDE_PLUGIN_ROOT}` 形式。 | 毎回の変更。 |
| `logic` | **全自動**（CI） | unit の**起動ロジック**を単体で: worktree と same-dir の判定、`--name` / セッション名 prefix、未初期化・claude 欠落のガード。 | 毎回の変更。 |
| `service` | **全自動**（要 Docker） | unit が実際に **`systemctl --user` サービスとして起動**: 基底プロセスの引数と `RCD_INSTANCE` を same-dir / worktree 両方で確認。 | 毎回の変更（Docker が使える環境で）。 |
| `skill` | **半自動** | 実 Claude が **`SKILL.md` を辿る**こと: プラグインのロード、`/rcd` 解決、`init` が設定を記録し unit を導入、`start` がインスタンス dir を作成し unit を enable、不正名の拒否。 | skill の文面・梱包・`claude` CLI が変わったとき（下記）。 |
| `live` | **手動** | スタブでは届かない **`claude remote-control` のライブ実行時挙動**: on-demand/worktree セッションへの `RCD_INSTANCE` 継承、claude.ai/code のセッション名形式、ライブセッションでの SELF 拒否・typed confirm。 | ベースライン確立、または unit の識別/命名配線か外部の `claude`/claude.ai 挙動が変わったとき（下記）。 |

`skill` と `live` は受け入れハーネス（`test/acceptance/`）の2モード。同じ実行が
`skill` 検査を自動で走らせ、`live` 検査は手で行う分として残す。

## 全自動 — 継続テスト

hermetic（スタブ `claude`）。これが継続的な安全網。

```sh
./test/run.sh        # lint + logic — Docker・ネット不要、CI-safe
./test/service.sh    # service — systemd Docker コンテナをビルドしそこで実行
```

`lint` は外部リンタ `skill-tools` / `claudelint` がインストール済み（または
`RCD_LINT_EXTERNAL=1`）のとき任意で走る。npm パッケージを取得するためオプトイン
で、既定は無効。

## 半自動 — `skill`

**目的:** 実 Claude が `SKILL.md` を読んで正しく振る舞うかを確認する — 決定的な
層では判定できない部分（あちらは構造を見るだけで、文面を Claude が辿るかは見ない）。
これには `setup-token`（inference スコープ）で足りる。

```sh
claude setup-token                 # Claude サブスクリプションが必要
export CLAUDE_CODE_OAUTH_TOKEN=<token>
./test/acceptance/run-acceptance.sh
./test/acceptance/run-acceptance.sh --teardown   # 終わったら
```

大半は機械判定だが、一部のモデル判断項目（例: 不正名をどう拒否するか）は自動採点
せず**読んで確認する用に出力**される。

**走らせるとき:**

- `SKILL.md` の文面が変わったとき（verb の手順、名前ルール、同梱ファイルの参照方法）
  — `lint` が通っても文言で Claude の挙動が変わりうる。
- プラグインの梱包が変わったとき（`plugin.json` / `marketplace.json`、ディレクトリ
  構成、skill 名、unit の位置）— ロードと `/rcd` 解決に影響する。
- `claude` CLI をメジャー級／挙動に影響する版へ更新したとき。

## 手動 — `live`

**目的:** スタブでは再現できない `claude remote-control` のライブ挙動を検証する。
リレーと spawn されるセッションを使うため、**full `claude auth login`**（`setup-token`
は inference 専用で `claude remote-control` を起動できない）と claude.ai/code アプリ
が必要。

**手順。** 起動中のコンテナ `rcd-acceptance-run` と、直前の `skill` 実行で記録済みの
rcd 設定を再利用する。`rcd` はコンテナ内ユーザ（uid 1000）。

1. full スコープのトークンでログインする（表示される URL / デバイスコードの指示に従う）:

   ```sh
   docker exec -it -u rcd rcd-acceptance-run claude auth login
   ```

2. ディレクトリが git 最上位のインスタンスを起動し（on-demand セッションが worktree
   になる）、基底セッションが実際に立ち上がったことを確認する:

   ```sh
   docker exec -it -u rcd rcd-acceptance-run bash -lc '
     export XDG_RUNTIME_DIR=/run/user/1000
     mkdir -p ~/rcdtest-root/rcdtest-live && git -C ~/rcdtest-root/rcdtest-live init -q
     systemctl --user enable --now claude-remote-control@rcdtest-live.service
     sleep 3; systemctl --user is-active claude-remote-control@rcdtest-live.service'
   ```

   `active` を期待。`activating`（自動再起動ループ）のままならログインが効いていない
   ので手順1をやり直す。

3. claude.ai/code（Web かアプリ）で基底セッション `rcdtest-host-rcdtest-live-base`
   を見つけ、そのインスタンスで**新規**セッションを開く。これが on-demand（worktree）
   セッションを spawn する。

4. その on-demand セッション内で、スタブでは確認できない2点を確認する:

   - `echo "$RCD_INSTANCE"` が `rcdtest-live` を表示すること。on-demand/worktree
     セッションに env が継承されている＝self 検出の前提。空なら継承されておらず欠陥。
   - セッションの表示名が `rcdtest-host-rcdtest-live-<auto>` の `-` 区切り形式である
     こと。

5. 同じ on-demand セッション内で自己保護を確認する:

   - `/rcd stop rcdtest-live` と `/rcd destroy rcdtest-live` は両方**拒否**される
     こと（自分自身＝SELF の中にいるため）。
   - `/rcd restart-all` は他を再起動し、SELF は後回し（detached な再起動）にすること。

6. 後片付けと使い捨てセッションの削除:

   ```sh
   ./test/acceptance/run-acceptance.sh --teardown
   ```

   その後 claude.ai/code に残った `rcdtest-host-*` セッションを削除する。

**走らせるとき:**

- これらの挙動に依拠する前のベースライン確立。
- unit の識別/命名/spawn 配線が変わったとき（`RCD_INSTANCE`、`--name`、
  セッション名 prefix、`--spawn`）。
- `claude` CLI か claude.ai が remote-control の env 継承やセッション名描画を変えた
  疑いがあるとき、または self 検出／命名の契約が変わったとき。

## 補足

- **`skill` と `live` は設計上、手動**。CI に組み込んだり自動実行したりしない。
  認証情報が要り、`live` は人の判断が要る。
- **発見は昇格させる。** `skill` や `live` で最初に捕えた失敗は、可能なら
  `lint` / `logic` の検査に移し、同種のバグが次回から自動で捕まるようにして、
  手動の面を縮小する。
