#!/usr/bin/env bash
# logic: verify the unit's launch logic in isolation (no systemd, no real claude).
# Extracts the ExecStart inline shell from the shipped unit, runs it against a
# stub `claude` for each directory condition, and asserts the resulting
# --spawn / --name / --remote-control-session-name-prefix and the guards.
set -uo pipefail
cd "$(dirname "$0")/.."                       # repo root
UNIT=units/claude-remote-control@.service
STUB="$PWD/test/stub-claude"
HOST=myhost
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  PASS %s\n' "$1"; }
ng(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# --- extract the ExecStart body: ExecStart=/bin/sh -c '<body>' ---
raw="$(grep -m1 "^ExecStart=/bin/sh -c '" "$UNIT")" || { echo "no ExecStart in $UNIT"; exit 1; }
body="${raw#*-c \'}"; body="${body%\'}"       # strip wrapper quotes
body="${body//\$\$/\$}"                        # systemd $$ -> literal $
body="${body//%H/$HOST}"                       # expand host specifier

# run the launch logic for instance <inst> in a private HOME; echo "<rc>|<record>"
launch(){ # $1=inst  $2=home
  local inst="$1" home="$2"
  local b="${body//%i/$inst}"
  HOME="$home" RCD_STUB_RECORD="$home/rec" RCD_STUB_ONESHOT=1 \
    sh -c "$b" >"$home/out" 2>"$home/err"
  echo "$?"
}
setup(){ # create config pointing root at <home>/insroot with the stub
  local home="$1" root="$1/insroot"
  mkdir -p "$home/.config/rcd" "$root"
  printf '%s\n' "$root" >"$home/.config/rcd/root"
  printf '%s\n' "$STUB" >"$home/.config/rcd/claude-bin"
}
argv(){ sed -n 's/^ARGV: //p' "$1/rec" 2>/dev/null; }

# 1) instance dir is a git repo top WITH a commit -> worktree
h="$(mktemp -d)"; setup "$h"; mkdir -p "$h/insroot/repo-top"; git -C "$h/insroot/repo-top" init -q
git -C "$h/insroot/repo-top" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
rc="$(launch repo-top "$h")"; a="$(argv "$h")"
[ "$rc" = 0 ] && echo "$a" | grep -q -- '--spawn worktree' && ok "git-top(committed) -> --spawn worktree" || ng "git-top -> worktree (rc=$rc argv=$a)"
echo "$a" | grep -q -- "--name $HOST-repo-top-base" && ok "git-top -> --name $HOST-repo-top-base" || ng "git-top naming ($a)"
echo "$a" | grep -q -- "--remote-control-session-name-prefix $HOST-repo-top" && ok "git-top -> prefix" || ng "git-top prefix ($a)"

# 1b) git top-level but NO commits (empty repo) -> same-dir (worktree add needs HEAD)
h="$(mktemp -d)"; setup "$h"; mkdir -p "$h/insroot/empty-repo"; git -C "$h/insroot/empty-repo" init -q
rc="$(launch empty-repo "$h")"; a="$(argv "$h")"
[ "$rc" = 0 ] && echo "$a" | grep -q -- '--spawn same-dir' && ok "empty-git -> --spawn same-dir" || ng "empty-git -> same-dir (rc=$rc argv=$a)"

# 2) instance dir is a plain subdir inside a parent repo -> same-dir (no worktree)
h="$(mktemp -d)"; setup "$h"; git -C "$h/insroot" init -q; mkdir -p "$h/insroot/child"
rc="$(launch child "$h")"; a="$(argv "$h")"
[ "$rc" = 0 ] && echo "$a" | grep -q -- '--spawn same-dir' && ok "child-of-repo -> --spawn same-dir" || ng "child-of-repo -> same-dir (rc=$rc argv=$a)"

# 3) plain non-git dir -> same-dir
h="$(mktemp -d)"; setup "$h"
rc="$(launch plain "$h")"; a="$(argv "$h")"
[ "$rc" = 0 ] && echo "$a" | grep -q -- '--spawn same-dir' && ok "non-git -> --spawn same-dir" || ng "non-git -> same-dir (rc=$rc argv=$a)"

# 4) cwd of the launched process is the instance directory
echo "$(sed -n 's/^CWD: //p' "$h/rec")" | grep -q "/insroot/plain$" && ok "cwd is <root>/<name>" || ng "cwd ($(sed -n 's/^CWD: //p' "$h/rec"))"

# 5) guard: root not configured -> exit non-zero, no launch
h="$(mktemp -d)"; mkdir -p "$h/.config/rcd"; printf '%s\n' "$STUB" >"$h/.config/rcd/claude-bin"
rc="$(launch plain "$h")"
{ [ "$rc" != 0 ] && grep -qi 'not initialized' "$h/err"; } && ok "missing root -> fails 'not initialized'" || ng "missing-root guard (rc=$rc err=$(cat "$h/err"))"

# 6) guard: claude-bin missing/non-executable -> exit non-zero, no launch
h="$(mktemp -d)"; mkdir -p "$h/.config/rcd" "$h/insroot"; printf '%s\n' "$h/insroot" >"$h/.config/rcd/root"
rc="$(launch plain "$h")"
{ [ "$rc" != 0 ] && grep -qi 'claude path missing' "$h/err"; } && ok "missing claude-bin -> fails 'claude path missing'" || ng "claude-bin guard (rc=$rc err=$(cat "$h/err"))"

echo "logic: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
