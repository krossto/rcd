# Codex レビュー判断: rcd 受け入れ検証プラン (round 1)

- 対象: `docs/superpowers/plans/2026-06-11-rcd-naming-and-worktree.md`
- ラウンド: 1
- overall: revise / confidence: 0.86
- 講評: unit 受け入れ検証としては近いが、`/rcd` 実コマンド経路・repo 最上位限定 worktree の重要ケース・検証環境保護が不足。

| ID | 深刻度 | 指摘(要約) | 判断 | 反映 |
|---|---|---|---|---|
| F1 | important | `init 相当`/`start 相当` を手動代替し実 `/rcd` 経路を通らない＋Red→実装→Green の形でない | 採用 | Task を実 `/rcd init`/`/rcd start` 呼び出しに変更。Task 0 Step3 に未初期化 Red、Task1 に init の Green、Task5 に名前検証を追加。 |
| F2 | important | spec 明示の「親リポジトリ配下にあるだけ=same-dir」ケースを未検証 | 採用 | Task 3 を新設：root 自体を git 化し子 `rcdtest-child` を起動、`--spawn same-dir` を期待。 |
| F3 | important | 実ユーザーの `~/.config/rcd/*` と installed unit を退避なく上書き | 採用 | Task 0 で固定パスへ退避、Task 7 で復元。検証は `mktemp -d` の TESTROOT を使用。 |
| F4 | minor | SELF 安全性が手動確認のみで実行コマンド/期待値が無い | 採用 | Task 6 を具体化：stop/destroy SELF の拒否＋`is-active=active`、restart-all の SELF 後回し detached、`$RCD_INSTANCE` 由来の確認。 |

## 反映先

- plan: `docs/superpowers/plans/2026-06-11-rcd-naming-and-worktree.md`（Task 0–7 に再編）
