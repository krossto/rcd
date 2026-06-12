# Codex Review Judgment: rcd 受け入れ単位設計 spec (round 1)

- Target: `docs/superpowers/specs/2026-06-12-rcd-acceptance-units-design.md`
- Round: 1
- Codex thread_id: 019eb9bd-43e3-7313-8834-03e267b65f67
- overall: revise / confidence: 0.88
- Summary: 高レベルの3分割は妥当だが、実装に直結する未決事項が残り過小定義。planner に渡す前に締める必要あり。全4件を accept し spec に反映した。

| ID | Severity | Finding（要約） | Decision | Reason |
|---|---|---|---|---|
| F1 | important | §8 が3つの未決（信頼の扱い／skill を headless のままか／guards の SELF 準備）を残す | accept | spec の目的（各単位の what/where/when を一意化）に反する。既定が明確なので確定: 信頼=(a) SKILL.md 注記、skill=headless 据置、guards SELF=スタブ unit で具体化。§8 を「決定事項」に改訂。 |
| F2 | important | guards は inference 前提だが可視 unit が要る。inference 実 claude では `remote-control` 起動不可で unit が不安定。skill の SELF 確認は `--all` 無しゆえ enable だけでは listed されない | accept | 技術的に正しい。対処は guards 対象 unit を**スタブ `claude-bin`** で active・listed にする（§4 guards・§6-7 追記）。代替の「skill SELF 確認に `--all` 追加」は**却下**（テスト都合で本体設計を歪めるため）。 |
| F3 | important | skill は機械判定と謳うが不正名拒否が「人が読む/モデル判断」 | accept | 副作用で機械判定可（dir 未作成・unit 未 enable をアサート、文言は advisory）。研究メモの方針とも整合。#4 を機械判定に変更し skill を完全機械判定化。 |
| F4 | minor | plugin ロード/`/rcd` 解決の判定シグナル未定義（grep に流れる恐れ） | accept | `system/init` の `plugins`/`plugin_errors`/`slash_commands` で判定する要件を §4 skill に明記（研究メモの結論）。 |
