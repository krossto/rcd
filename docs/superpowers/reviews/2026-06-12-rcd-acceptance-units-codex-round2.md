# Codex Review Judgment: rcd 受け入れ単位設計 spec (round 2)

- Target: `docs/superpowers/specs/2026-06-12-rcd-acceptance-units-design.md`
- Round: 2
- Codex thread_id: 019eb9bd-43e3-7313-8834-03e267b65f67
- overall: revise / confidence: 0.86
- Summary: F1–F4 は解決済みとして撤回。更新版はより締まったが、guards/skill に新規2件。両件 accept・反映。

| ID | Severity | Finding（要約） | Decision | Reason |
|---|---|---|---|---|
| F1–F4 | — | round1 指摘 | withdrawn（Codex） | 解決済みとして撤回 |
| F5 | important | guards に SELF unit はあるが destroy の typed-confirm 用の非 SELF 犠牲 unit が無い（SELF は確認前に拒否されるため #5 を確認できない） | accept | 正しい。`rcdtest-victim`（非 SELF・active・スタブ）を追加し、誤/空確認では残存・正確な確認でのみ削除をアサート。§4 guards に2フィクスチャを明記。 |
| F6 | minor | #4 の副作用アサートが広すぎ、#3 の正当 start で enable 済み unit と混同しうる | accept | 正しい。不正名試行の前後差分でスコープ（#3 より前、または前後の unit 一覧/`<root>` 状態の不変をアサート）。§4 skill #4 を修正。 |
