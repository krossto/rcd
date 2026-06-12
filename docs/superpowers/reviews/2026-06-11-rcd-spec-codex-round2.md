# Codex レビュー判断: rcd 設計 spec (round 2)

- 対象: `docs/superpowers/specs/2026-06-11-rcd-naming-and-worktree-design.md`
- ラウンド: 2 / overall: revise → 反映で収束 / confidence: 0.84
- 講評: F1 解消。F2〜F5 に未検証前提・edge case が残るとの再主張。全採用し反映。

| ID | 深刻度 | 指摘(要約) | 判断 | 反映 |
|---|---|---|---|---|
| F2 | important | `RCD_INSTANCE` の on-demand/worktree 継承が未検証で根拠不足 | 採用 | spec に「継承の必須検証＋非継承時フォールバック（worktree メタデータ逆引き）」を明記。plan Task 4 Step3 を worktree セッション内 `echo $RCD_INSTANCE` 検証に強化。 |
| F3 | important | `claude-bin` 欠落時に `claude` へ fallback、絶対パス保証が弱い | 採用 | unit は `[ -x "$bin" ]` で失敗（fallback 削除）。init は絶対パス＋`test -x` を満たす値のみ記録。spec/SKILL 更新。 |
| F4 | important | SELF 単独時の restart-all 手順未定義 | 採用 | spec/SKILL に「他が空なら restart を skip し SELF detached のみ」。plan Task 6 Step4 を追加。 |
| F5 | minor | オンデマンド名区切りが未決で記述不揃い | 採用 | spec で `<hostname>-<name>-<自動名>` を確定（CLI が `-` 挿入＝既定 prefix=hostname と同挙動）。受け入れ検証で確認、暫定文を削除。 |

収束: `convergence.sh` → `RESULT=converged` / `UNRESOLVED=`。
