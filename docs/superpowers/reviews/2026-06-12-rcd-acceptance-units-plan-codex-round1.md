# Codex Review Judgment: rcd 受け入れ単位 plan (round 1)

- Target: `docs/superpowers/plans/2026-06-12-rcd-acceptance-units.md`
- Round: 1
- Codex thread_id: 019eb9c9-df73-7442-b29c-3c0f241dc99c
- overall: revise / confidence: 0.90
- Summary: spec とほぼ一致だが、実行細部で単位が失敗 or 重要回帰を見逃す箇所あり。全5件 accept・反映。

| ID | Severity | Finding（要約） | Decision | Reason |
|---|---|---|---|---|
| F1 | important | skill 不正名チェックが `~/rcdtest-root` と unit-files のみ snapshot、`../evil`→`~/evil` のトラバーサルを検出しない | accept | 最重要の名前ガード。親スコープ＋`test ! -e ~/evil` を追加。 |
| F2 | important | guards が spec の inference 境界から逸脱（token 不要・対話ログイン前提） | accept | spec では guards=setup-token。token を要求し `-e` で渡す。README/manual-acceptance も「docker+setup-token」に。 |
| F3 | important | guards 対話起動で `XDG_RUNTIME_DIR` 未 export → `systemctl --user` 失敗 | accept | 起動 `bash -lc` で export、加えて fixture active のプリフライト。 |
| F4 | important | `skill/guards/live.sh` に実行ビット無し、`./*.sh` 起動が Permission denied | accept | 各タスクに `chmod +x`＋`test -x` 検証を追加。 |
| F5 | minor | `rcd_boot` がタイムアウト時に失敗しない | accept | 各待機後に条件検証＋診断出力して `exit 1`。 |
