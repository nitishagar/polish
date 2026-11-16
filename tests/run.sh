#!/usr/bin/env bash
# tests/run.sh: dependency-free test runner. Fails nonzero on any failure.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1: $2"; }

# 1. bin/polish basics
out="$("$ROOT/bin/polish" --version)" && ok "polish --version" || bad "polish --version" "$out"
"$ROOT/bin/polish" doctor >/dev/null && ok "polish doctor" || bad "polish doctor" "nonzero"
"$ROOT/bin/polish" agents | grep -q claude && ok "polish agents lists claude" || bad "polish agents" "no claude row"
[ "$("$ROOT/bin/polish" bogus 2>&1 >/dev/null)" != "" ] && ok "polish unknown cmd errors" || bad "polish unknown cmd" "silent"

# 2. shell syntax of every script
for f in "$ROOT"/bin/* "$ROOT"/installer/install.sh "$ROOT"/tests/run.sh; do
  bash -n "$f" && ok "bash -n $(basename "$f")" || bad "bash -n $(basename "$f")" "syntax error"
done

# 3. installer uninstall is a clean no-op on empty home
fakehome="$(mktemp -d)"; touch "$fakehome/.bashrc"
HOME="$fakehome" SHELL=/bin/bash "$ROOT/installer/install.sh" --uninstall --shell bash --share "$fakehome/share" >/dev/null \
  && ok "installer --uninstall no-op" || bad "installer --uninstall" "nonzero"
grep -q "polish" "$fakehome/.bashrc" && bad "installer --uninstall" "left hook" || ok "installer --uninstall leaves rc clean"
rm -rf "$fakehome"

# 4. repo hygiene: LICENSE present, no co-author trailers needed, thoughts/ ignored
[ -f "$ROOT/LICENSE" ] && ok "LICENSE present" || bad "LICENSE" "missing"
(cd "$ROOT" && git check-ignore -q thoughts/ledger.md 2>/dev/null) && ok "thoughts/ ignored" || bad "thoughts/ ignored" "not ignored"

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
