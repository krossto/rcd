#!/usr/bin/env bash
# lint: validate the skill/plugin definition without a real Claude.
# Default checks are local and dependency-free (CI-safe, no network).
# Optional external linters (skill-tools, claudelint) run only when present on
# PATH or RCD_LINT_EXTERNAL=1 — they download npm packages, so they are opt-in.
set -uo pipefail
cd "$(dirname "$0")/.."
SKILL=skills/rcd/SKILL.md
UNIT=units/claude-remote-control@.service
fail=0
ok(){ printf '  PASS %s\n' "$1"; }
ng(){ fail=1; printf '  FAIL %s\n' "$1"; }

# --- frontmatter structure ---
head -1 "$SKILL" | grep -qx -- '---' && ok "frontmatter opens with ---" || ng "missing frontmatter"
fm="$(awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f' "$SKILL")"
for k in name description allowed-tools; do
  printf '%s\n' "$fm" | grep -q "^$k:" && ok "frontmatter has $k" || ng "frontmatter missing $k"
done
printf '%s\n' "$fm" | grep -q '^description: .\{20,\}' && ok "description is non-trivial" || ng "description too short/empty"

# --- unit sanity ---
grep -q '^ExecStart=/bin/sh -c' "$UNIT" && ok "unit has inline ExecStart" || ng "unit ExecStart missing"
grep -q '^Environment=RCD_INSTANCE=%i' "$UNIT" && ok "unit sets RCD_INSTANCE" || ng "unit missing RCD_INSTANCE wiring"
# the inline ExecStart shell must be syntactically valid
body="$(grep -m1 "^ExecStart=/bin/sh -c '" "$UNIT")"; body="${body#*-c \'}"; body="${body%\'}"; body="${body//\$\$/\$}"; body="${body//%i/X}"; body="${body//%H/H}"
sh -n -c "$body" 2>/dev/null && ok "unit inline shell parses" || ng "unit inline shell is not valid sh"

# --- allowed-tools covers commands used in the body ---
bash test/check-allowed-tools.sh "$SKILL" >/dev/null 2>&1 && ok "allowed-tools covers body commands" || { ng "allowed-tools coverage"; bash test/check-allowed-tools.sh "$SKILL" | sed 's/^/    /'; }

# --- optional external linters (opt-in; they fetch npm packages) ---
run_external(){ [ -n "${RCD_LINT_EXTERNAL:-}" ] || command -v "$1" >/dev/null 2>&1; }
if run_external skill-tools; then
  echo "  (running skill-tools check)"; skill-tools check "$SKILL" || ng "skill-tools reported issues"
else
  echo "  SKIP skill-tools (optional; set RCD_LINT_EXTERNAL=1 with it installed)"
fi
if run_external claudelint; then
  echo "  (running claudelint validate-skills)"; claudelint validate-skills || ng "claudelint reported issues"
else
  echo "  SKIP claudelint (optional; set RCD_LINT_EXTERNAL=1 with it installed)"
fi

[ "$fail" -eq 0 ] && echo "lint: OK" || { echo "lint: FAILED"; exit 1; }
