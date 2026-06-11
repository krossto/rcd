# Codex レビュー判断: rcd 設計 spec (round 1)

- 対象: `docs/superpowers/specs/2026-06-11-rcd-naming-and-worktree-design.md`
- ラウンド: 1
- overall: revise / confidence: 0.86
- 講評: 方向性は妥当だが、公開配布前提として name 入力制約・SELF 検出・実行パス解決に未確定リスク。

| ID | 深刻度 | 指摘(要約) | 判断 | 反映 |
|---|---|---|---|---|
| F1 | important | `<name>` の許可文字/長さ/予約値が未定義（dir名・systemd・session名に直結） | 採用 | spec に「Instance name の検証」節を追加（`^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$`、`.`/`..`/`.service`末尾/`/`/空白/`@`/`%` 拒否）。SKILL.md の dispatch に検証ステップ追加。 |
| F2 | critical | worktree/on-demand セッションでは cwd が `<name>` でなく `basename $PWD` 方式の SELF 検出が破綻し、自分の接続を切れる | 採用 | unit に `Environment=RCD_INSTANCE=%i`（子セッションに継承）。SKILL.md の SELF 検出を `$RCD_INSTANCE` 優先・cwd はフォールバックに。spec 安全性も更新。 |
| F3 | important | 「claude インストール先非依存」と固定 PATH の `exec claude` が矛盾（user unit は対話 shell の PATH を読まない） | 採用 | `/rcd init` が `command -v claude` を `~/.config/rcd/claude-bin` に記録、unit はそれを `exec`。PATH は git/シェル用に縮小。spec/README/SKILL 更新。 |
| F4 | important | `restart-all` の SELF 含む手順・`systemd-run` 権限が設計/allowed-tools に無い（私の SKILL 改訂で systemd-run を落としたリグレッション） | 採用 | SKILL.md allowed-tools に `Bash(systemd-run --user *)` 復元。spec 安全性に restart-all 完全手順を明記。 |
| F5 | minor | オンデマンド session 名の区切り `-` 有無が未検証 | 採用 | spec に CLI 依存の注記、受け入れ検証（plan Task4 Step3）で実 session 名を確認し必要なら prefix を `%H-%i-` に。 |

## 反映先

- unit: `units/claude-remote-control@.service`（RCD_INSTANCE, claude-bin）
- skill: `skills/rcd/SKILL.md`（allowed-tools, SELF 検出, name 検証, init の claude 記録）
- spec/README: 上記反映
