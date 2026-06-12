# RCD spawn 判定 — 空 git リポは worktree でなく same-dir にフォールバック

> 受け入れ単位 `live` のデバッグで判明した、`claude-remote-control@.service` の spawn 判定の堅牢性ギャップと、その是正の設計。関連: `units/claude-remote-control@.service`、`skills/rcd/SKILL.md`（`start` / Notes）、`test/logic.sh`、`docs/superpowers/specs/2026-06-12-rcd-acceptance-units-design.md`、`docs/superpowers/specs/2026-06-12-rcd-live-consent-session-name.md`。

## 1. 背景・問題

`/rcd start <name>` が起動する base セッションは、インスタンス dir が git の最上位なら on-demand セッションを git worktree で隔離（`--spawn worktree`）、そうでなければ同一 dir 共有（`--spawn same-dir`）で動く。判定はユニットの ExecStart 内インラインシェル:

```sh
if [ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$(pwd -P)" ]; then spawn=worktree; else spawn=same-dir; fi
```

問題: この判定は「**git 最上位か**」だけを見て、**コミット(HEAD)の有無を見ていない**。`git init` 直後の**空リポ（コミット0）でも `git rev-parse --show-toplevel` は成功**するため `--spawn worktree` が選ばれるが、`git worktree add` は HEAD コミットが無いと失敗する。結果、on-demand セッションが生成できず、claude.ai/code 上では「クラウドコンテナをセットアップ中」のまま**無言で固着**する（エラー表示なし＝原因が分かりにくい）。

## 2. 影響（実ユーザ・テスト両方）

- **実ユーザ**: 新規プロジェクト dir を `git init` した直後（初回コミット前）に `/rcd start` すると、本番でも同じ無言固着が起きる。稀だが現実に起こり得る操作順で、失敗が不透明。
- **受け入れ `live`**: step1 が `git init` のみ（コミット無し）だったため worktree spawn が失敗し固着した（実機 WSL2 で確認。base ジャーナルは `Capacity: 1/32` だが `git worktree list` に新規 worktree 無し）。`1fa00ec` で step1 に初期コミットを追加して回避済みだが、これは**テスト側の回避**で、製品の判定自体は未修正。
- **`test/logic.sh`**: 現在の #1「git-top → worktree」フィクスチャは**空リポ**で、ユニットが argv に `--spawn worktree` を出すことだけを検査している（実 spawn は検査しない）ため、この実行時失敗を捕捉できていない。

## 3. 根本原因

worktree 適格性の判定が不完全。「git 最上位」は worktree の**必要条件だが十分条件ではない**。`git worktree add` には**到達可能な HEAD コミットが必須**。空リポはこの条件を満たさない。

## 4. 設計（変更内容）

ユニットの spawn 判定を「**git 最上位 かつ HEAD コミットが存在する時のみ worktree、それ以外は same-dir**」に変更し、空リポを same-dir に自動フォールバックさせる:

```sh
if [ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$(pwd -P)" ] && git rev-parse --verify -q HEAD >/dev/null 2>&1; then
  spawn=worktree
else
  spawn=same-dir
fi
```

- `git rev-parse --verify -q HEAD` は HEAD が解決できれば 0、空リポ等で解決できなければ非0。
- 既存の `$$`（systemd 指定子のリテラル `$` エスケープ）方式と整合させて ExecStart に埋め込む。
- 追加の外部コマンドは無し（`git` は既存判定で使用済み、PATH も既設定）。

## 5. 影響範囲（出力物）

| ファイル | 変更 |
|---|---|
| `units/claude-remote-control@.service` | ExecStart の spawn 判定に `&& git rev-parse --verify -q HEAD` を追加 |
| `test/logic.sh` | #1「git-top → worktree」のフィクスチャを**コミット付きリポ**に修正（worktree が正しく選ばれる前提に）。さらに新ケース「**git 最上位だがコミット0（空リポ）→ same-dir**」を追加 |
| `test/service/run-in-container.sh` | B) worktree ケース（`assert_inst rcdtest-wt worktree`）のフィクスチャ `rcdtest-wt` を**初期コミット付き**にする（現状 `git init` のみ＝空リポで、fix 後 same-dir に回帰するため）。任意で「空リポ→same-dir」の service ケースを追加。あるいは「空リポ分岐は logic が担保、service は commit 付き worktree のみ」と明記 |
| `skills/rcd/SKILL.md` | 「git 最上位 → worktree」の散文を「git 最上位**でコミットあり** → worktree、無ければ（非 git／コミット0）same-dir」に更新（該当箇所: 冒頭の挙動説明、`start` の Report 注記） |
| `README.md` | 「Naming and worktrees」節（L74-76）の「`git init` / `git clone` で worktree 有効化」を「**コミットのある** git 最上位（clone 済み、または `git init` ＋初回コミット）で worktree、それ以外は same-dir」に更新 |
| `docs/superpowers/specs/2026-06-11-rcd-naming-and-worktree-design.md` | 旧設計の「git 最上位のみで worktree」記述（worktree 自動判定節）を、HEAD コミット必須に更新（または本 spec で上書きする旨の superseded 注記） |
| `docs/manual-acceptance.md` / 本 spec 群 | worktree 条件への言及があれば整合（live は既にコミットを seed 済みで挙動不変） |

`test/lint.sh` は unit のインラインシェルが解析可能であること等を見るが、本変更は構文を壊さず allowed-tools にも影響しない（緑のまま想定）。

## 6. エッジケース・リスク

1. **既存挙動の変化**: 空リポのみ「worktree（壊れ）→ same-dir（動作）」へ変わる。コミットありリポ・非 git dir・親リポ配下の子 dir の判定は不変。実質「壊れていたケースが動くようになる」だけで回帰なし。
2. **detached HEAD / 異常状態**: 1つでもコミットが到達可能なら `git rev-parse --verify HEAD` は成功し worktree。問題なし。
3. **性能**: ユニット起動時に git 呼び出しが1回増えるのみ。無視できる。
4. **same-dir の含意**: 空リポが same-dir になると、on-demand セッションは worktree 隔離されず同一 dir を共有する。空リポ（中身ほぼ無し）では実害は小さい。spawn mode は**サービス起動時にのみ評価**される点に注意: 後でコミットしても `/rcd start <name>` は**冪等で稼働中サービスを再起動しない**ため自動では worktree に切り替わらない。切り替えるには初回コミット後に**サービスを再起動**する（`/rcd stop <name>` → `/rcd start <name>`、または `systemctl --user restart claude-remote-control@<name>.service`、または `/rcd restart-all`）。この点は SKILL.md / README の文言にも反映する。

## 7. 検証

- **自動（CI・決定的）**: `test/logic.sh` の更新で、(a) コミット付き git 最上位 → worktree、(b) 空リポ → same-dir、(c) 既存の非 git / 子 dir → same-dir を網羅。`./test/run.sh` 緑。
- **service（Docker+systemd stub）**: `test/service/run-in-container.sh` の worktree フィクスチャ `rcdtest-wt` を初期コミット付きにして B) を維持。空リポ→same-dir の分岐は logic が担保するため service では必須としない（必要なら service にも空リポケースを追加）。
- **手動（任意）**: 製品挙動としては logic が argv 判定を担保。実 spawn の成立は `live`（コミット seed 済み worktree 経路）で別途確認済み。空リポ→same-dir の実 spawn まで見たい場合のみ手動で確認。

## 8. 非目標

- worktree 作成失敗時の実行時リカバリ（リトライ等）は対象外。判定段階で空リポを same-dir に倒すことで、そもそも失敗経路に入らないようにする。
- claude.ai 側の「セットアップ中」無言固着 UI そのものの改善は当方の管轄外（Anthropic 側）。
