# Codex Review Judgment: rcd-worktree-empty-repo-fallback (round 1)

- Target: docs/superpowers/specs/2026-06-12-rcd-worktree-empty-repo-fallback.md
- Round: 1
- Codex thread_id: (see r1)
- overall: revise / confidence: 0.88
- Summary: Core fix sound; three scope/wording gaps. All three accepted and applied to the spec.

| ID | Severity | Finding (summary) | Decision | Reason |
|---|---|---|---|---|
| F1 | important | `test/service/run-in-container.sh` also builds its worktree fixture (`rcdtest-wt`) with `git init` only and asserts `--spawn worktree`; after the unit change it becomes an empty repo → `same-dir`, regressing the Docker service test. Spec scope omitted it. | accept | Verified: service test B) `assert_inst rcdtest-wt worktree`. Added `test/service/run-in-container.sh` to the §5 output table (seed an initial commit for `rcdtest-wt`; empty-repo branch covered by logic) and noted it in §7 verification. |
| F2 | important | Docs scope omitted stale worktree-eligibility wording outside SKILL.md: top-level `README.md` ("`git init` enables worktree mode") and the older design spec `2026-06-11-rcd-naming-and-worktree-design.md` (worktree = git top-level only). | accept | Verified both. Added `README.md` and the 2026-06-11 spec to the §5 table, with wording to require a git top-level **with a resolvable HEAD** (clone with commits, or `git init` + initial commit). |
| F3 | minor | §6.4 said the user can commit later and "re-start" to switch same-dir→worktree, but `/rcd start` is idempotent and won't restart an already-active service, so the spawn predicate isn't re-evaluated. | accept | Corrected §6.4: spawn mode is computed only at service start; to switch after the first commit the user must restart the service (`/rcd stop`+`start`, `systemctl --user restart`, or `/rcd restart-all`). To be reflected in SKILL.md/README wording too. |
