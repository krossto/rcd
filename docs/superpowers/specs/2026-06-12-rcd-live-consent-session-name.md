# RCD live 単位 — remote-control consent とセッション表示名の問題（事象分析・要因・対応・修正）

> 受け入れ単位 `live`（`test/acceptance/live.sh`）の実行中に判明した、`claude remote-control` の初回 consent 処理に起因する「base セッションがアプリに正しい名前で出ない」問題の分析と、適用した修正の設計記録。関連: spec `2026-06-12-rcd-acceptance-units-design.md`、`skills/rcd/SKILL.md`、`units/claude-remote-control@.service`。

## 1. 背景

`live` 単位は、systemd ユーザユニット（`claude-remote-control@.service`）が起こす **base セッション**（`claude remote-control --name "<host>-<instance>-base" --remote-control-session-name-prefix "<host>-<instance>" --spawn worktree`）について、次の2点を claude.ai/code（Web/アプリ）から人手確認する:

1. base から開いた **on-demand セッションに `RCD_INSTANCE` が継承**される（self-detection の基盤）。
2. セッション**表示名が `<host>-<instance>-…` 形式**になる。

前段で判明済みの確定事実: `claude remote-control` は初回に **「Enable Remote Control? (y/n)」consent プロンプト**を出す。systemd は TTY 無しのため応答できず、未応答終了 → `Restart=always`×`StartLimitBurst=5` → `start-limit-hit` で `failed`。consent をバイパスする CLI フラグは存在しない。consent 受諾は `~/.claude.json` の `"remoteDialogSeen": true` として**マシン全体・1回**永続化される。

この consent を `live.sh` が事前に取る必要があり、当初は「`claude remote-control` を短時間だけ起動して `y` をパイプ投入し承諾する**プローブ方式**」を採った（`printf "y\n" | timeout 8 claude remote-control --name rcd-consent` をインスタンス dir で実行）。

## 2. 事象

WSL2/Docker 再起動後のクリーンな `live.sh` 実行で:

- step2 は `base session is-active: active` に到達（consent は事前承諾済みのため起動成功）。
- しかし claude.ai/code の Remote Control 一覧に **`rcdtest-host-rcdtest-live-base` が出ない**。代わりに **`rcd-consent`**（プローブ名）が `rcdtest-host` 配下に表示される。
- その `rcd-consent` を開くと「クラウドコンテナをセットアップ中」で停止（別物のクラウドセッション側に流れる）。
- スーパーリロードしても base 名は出ない（アプリのキャッシュ問題ではない）。

## 3. 調査と証拠

base ユニット（`claude-remote-control@rcdtest-live.service`）のジャーナル:

```
sh[263]: Capacity: 1/32 · New sessions will be created in an isolated worktree
sh[263]:     rcd-consent
sh[263]: Continue coding in ... https://claude.ai/code?environment=env_01Fx1Sb5H5kcNivCvzsXLAFm
...
sh[263]: ·✔︎· Connected · rcdtest-live
sh[263]:     Capacity: 0/32 · New sessions will be created in an isolated worktree
```

- `remoteDialogSeen": true`（consent は承諾済み）。
- base は最終的に `✔︎ Connected · rcdtest-live` ＝ **接続自体は成功**。
- しかし base のジャーナルに **同一 `environment=env_01Fx…` と `rcd-consent`** が現れる。これは base が**プローブと同じ relay environment に相乗り**していることを示す。

## 4. 想定した要因と検証

| 仮説 | 結果 | 根拠 |
|---|---|---|
| consent 未承諾で base が起動失敗 | 反証 | `is-active active`、`remoteDialogSeen: true` |
| ログイン未確立 | 反証 | step1 で full login 済、`✔︎ Connected` |
| base がリレー未接続 | 反証 | ジャーナルに `✔︎ Connected · rcdtest-live` |
| アプリのキャッシュ/反映遅延 | 反証 | スーパーリロードでも base 名出ず |
| **consent プローブがインスタンス dir に relay environment を作り、base が同一 environment に相乗りして表示名がプローブ名に奪われた** | **確証** | base ジャーナルに同一 `env_01Fx…` と `rcd-consent`。プローブと base は同一インスタンス dir で実行 |

## 5. 根本原因

consent を「**実際にリレーへ接続するプローブ**」で取得したこと。プローブ（`claude remote-control --name rcd-consent`）を **base と同じインスタンス dir** で実行したため、リレー上にそのディレクトリの environment（`env_01Fx…`、表示名 `rcd-consent`）が作られた。直後に起動した base は同一ディレクトリゆえ**同じ environment に join** し、自身の `--name`（`rcdtest-host-rcdtest-live-base`）ではなく**プローブ名 `rcd-consent` でアプリに表示**された。consent 自体（`remoteDialogSeen`）は正しく永続化されており、base の接続も成功している。問題は「consent 取得の副作用としての environment 汚染」のみ。

## 6. 対応方針

consent の取得を、**リレーへ接続しない**方法に変える。`remoteDialogSeen` は単なるローカル設定フラグ（マシン全体・1回）なので、`~/.claude.json` に**直接書き込む**ことで、リレー上に environment を一切作らずに承諾できる。これにより base が**唯一かつ最初の** remote-control 接続となり、自身の `--name` で正しく登録される。

代替案の比較:
- (A) プローブをインスタンス dir 以外（例 HOME）で実行 → environment 汚染を別ディレクトリに逃がせるが、なお relay にプローブ用 environment が残り、掃除が要る。
- (B) フラグ直書き（採用）→ relay 接続ゼロ、残骸ゼロ、最も確実。トレードオフは `~/.claude.json` の内部キー `remoteDialogSeen` に依存すること。

## 7. 修正内容（適用済み: コミット `ac94390`）

`test/acceptance/live.sh` step2 の consent 取得を、プローブからフラグ直書きへ置換:

```sh
# consent をリレー接続せずに承諾（environment 汚染を避ける）。jq はコンテナ同梱。
if [ -f ~/.claude.json ]; then
  t="$(mktemp)" && jq ".remoteDialogSeen = true" ~/.claude.json > "$t" && mv "$t" ~/.claude.json
else
  printf "%s\n" "{\"remoteDialogSeen\": true}" > ~/.claude.json
fi
```

関連する既存修正（先行コミット）:
- consent 取得そのものの導入と、`is-active == active` を成功条件に厳格化（`646e150`）。
- `SKILL.md` の初回注記を trust（dir 毎）＋ remote-control consent（マシン1回）両対応へ拡張（`646e150`）。これは実ユーザの初回 `/rcd start` も同じ failed を起こすため。
- アプリ確認文言から内部ラベル G4/G5 を除去（部外者に不明なため）。

## 8. リスク・トレードオフ・検討事項

1. **設定スキーマ依存**: `remoteDialogSeen` は claude の内部設定キー。将来キー名/形式が変われば直書きは無効化しうる（その場合 consent 未承諾で base が再び `start-limit-hit`）。検知策として step2 の `is-active == active` ゲートが残っているため、壊れれば `live` が落ちて気づける。
2. **実ユーザ側 (`SKILL.md`)（対応済み・決定）**: 実ユーザが consent を**インスタンス dir で**取ると、本番でも同じ environment 汚染（アプリ表示名がユーザの一時 consent セッション名に奪われ、`<hostname>-<name>-base` で出ない）が起きる。test 側のフラグ直書きは acceptance しか守らない。→ `SKILL.md` 初回注記を改訂し、手順を分離した: **trust はインスタンス dir で**（対話 `claude`）、**consent は非インスタンス dir（例 `cd ~ && claude remote-control`）で**取得し `y`→Ctrl+C、残る一時 consent セッションはアプリで削除可、と明記。これにより `/rcd start` の base が固有名で登録される。
3. **`live.sh` の冪等性**: 既に `remoteDialogSeen:true` の場合も jq 直書きは安全（上書き）。`~/.claude.json` が step1 ログイン後に必ず存在する前提だが、不在時の分岐も用意済み。
4. **検証可能性**: 本修正の効果（base が固有名で出る）は、claude.ai/code 表示というアプリ側挙動に依存し、自動テストでは確認できない。クリーン再実行＋人手確認が必要。

## 9. 検証状況（本ドキュメントの中心的検証・未完了）

**status: 未検証（blocking）。** 本修正の効果（base が固有名でアプリに出る）は claude.ai/code の表示に依存し自動テストでは確認できない。下記クリーン再実行を実施し、本節を**完了記録**（実施日 / `claude` CLI 版 / 各項目の pass・fail / base ジャーナル抜粋）に更新するまで、`live` 単位は合格としない。

クリーン再実行チェックリスト（`./test/acceptance/live.sh --teardown` → `git pull`（`ac94390` 取得）→ 再 login＋trust → step2 フラグ承諾 → step3 アプリ確認）:

- [ ] claude.ai/code 一覧に **`rcdtest-host-rcdtest-live-base`** が出る（`rcd-consent` は出ない）
- [ ] base ジャーナルに `rcd-consent` / 共有 environment が無い（`✔︎ Connected · rcdtest-live` のみ）
- [ ] base から開いた on-demand セッションで `echo "$RCD_INSTANCE"` → `rcdtest-live`
- [ ] 表示名が `rcdtest-host-rcdtest-live-<auto>` 形式（`-` 区切り）

完了したらこのチェックを記録に置換し、status を「検証済み」に更新する。
