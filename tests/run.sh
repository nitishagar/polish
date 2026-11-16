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

# 5. tokens collector suite (hook appended by tokens task; keep last).
"$ROOT/tests/test-tokens.sh" && ok "tokens suite" || bad "tokens suite" "see failures above"

# === BEGIN installer-tests (append-only block owned by installer task) ===
# 6. installer matrix on fake HOME: bash+zsh hooks idempotent, starship
#    backup, --timer units, uninstall restores rc + starship.
_fake="$(mktemp -d)"
echo "# my bashrc" > "$_fake/.bashrc"
echo "# my zshrc" > "$_fake/.zshrc"
mkdir -p "$_fake/.config"
echo "# user starship" > "$_fake/.config/starship.toml"
HOME="$_fake" SHELL=/bin/bash "$ROOT/installer/install.sh" --shell bash --from "$ROOT" --timer >/dev/null \
  && ok "installer bash from local dir" || bad "installer bash from local dir" "nonzero"
[ -x "$_fake/.local/share/polish/bin/polish" ] && ok "installer share populated" || bad "installer share" "missing bin/polish"
[ -L "$_fake/.local/bin/polish" ] && [ -L "$_fake/.local/bin/polish-tokens-collect" ] \
  && ok "installer prefix links" || bad "installer prefix links" "missing"
[ "$(grep -cF '# >>> polish >>>' "$_fake/.bashrc")" = 1 ] && ok "installer bash hook once" || bad "installer bash hook" "count != 1"
HOME="$_fake" SHELL=/bin/bash "$ROOT/installer/install.sh" --shell bash --from "$ROOT" >/dev/null \
  && ok "installer reinstall ok" || bad "installer reinstall" "nonzero"
[ "$(grep -cF '# >>> polish >>>' "$_fake/.bashrc")" = 1 ] && ok "installer bash hook idempotent" || bad "installer bash hook" "duplicated"
HOME="$_fake" SHELL=/bin/zsh "$ROOT/installer/install.sh" --shell zsh --from "$ROOT" >/dev/null \
  && ok "installer zsh hook" || bad "installer zsh hook" "nonzero"
grep -q 'init\.zsh' "$_fake/.zshrc" && ok "installer zsh sources init.zsh" || bad "installer zsh hook" "no init.zsh line"
[ -f "$_fake/.config/starship.toml.polish-bak" ] && grep -q "user starship" "$_fake/.config/starship.toml.polish-bak" \
  && ok "installer starship backup" || bad "installer starship backup" "missing/altered"
cmp -s "$ROOT/starship.toml" "$_fake/.config/starship.toml" && ok "installer starship deployed" || bad "installer starship" "not deployed"
[ -f "$_fake/.config/systemd/user/polish-tokens.timer" ] && [ -f "$_fake/.config/systemd/user/polish-tokens.service" ] \
  && ok "installer --timer units" || bad "installer --timer" "units missing"
grep -q "polish-tokens-collect" "$_fake/.config/systemd/user/polish-tokens.service" \
  && ok "installer service ExecStart" || bad "installer service" "bad ExecStart"
HOME="$_fake" SHELL=/bin/bash "$ROOT/installer/install.sh" --uninstall --shell bash >/dev/null \
  && ok "installer uninstall" || bad "installer uninstall" "nonzero"
grep -q "polish" "$_fake/.bashrc" && bad "installer uninstall rc" "hook left" || ok "installer uninstall restores rc"
grep -q "my bashrc" "$_fake/.bashrc" && ok "installer uninstall keeps user rc" || bad "installer uninstall rc" "user content lost"
[ ! -e "$_fake/.local/share/polish" ] && ok "installer uninstall removes share" || bad "installer uninstall share" "left behind"
[ ! -e "$_fake/.local/bin/polish" ] && [ ! -e "$_fake/.local/bin/polish-tokens-collect" ] \
  && ok "installer uninstall removes links" || bad "installer uninstall links" "left behind"
[ ! -e "$_fake/.config/systemd/user/polish-tokens.timer" ] && [ ! -e "$_fake/.config/systemd/user/polish-tokens.service" ] \
  && ok "installer uninstall removes timer" || bad "installer uninstall timer" "left behind"
grep -q "user starship" "$_fake/.config/starship.toml" && ok "installer uninstall restores starship" || bad "installer uninstall starship" "not restored"
rm -rf "$_fake"

# 7. init.zsh syntax (bash -n always; zsh -n when zsh exists) + unit sanity
bash -n "$ROOT/init.zsh" && ok "bash -n init.zsh" || bad "bash -n init.zsh" "syntax error"
if command -v zsh >/dev/null 2>&1; then
  zsh -n "$ROOT/init.zsh" && ok "zsh -n init.zsh" || bad "zsh -n init.zsh" "syntax error"
else
  ok "zsh -n init.zsh (skipped: no zsh)"
fi
grep -q '^ExecStart=.*polish-tokens-collect' "$ROOT/installer/polish-tokens.service" \
  && ok "service ExecStart key" || bad "service ExecStart key" "missing"
grep -q '^OnUnitActiveSec=' "$ROOT/installer/polish-tokens.timer" \
  && ok "timer OnUnitActiveSec key" || bad "timer OnUnitActiveSec key" "missing"

# 8. redteam regressions: tokens-table merge keys, codex prompt FP,
#    installer arg crash + partial-block uninstall guard.
_t8="$(mktemp -d)"
mkdir -p "$_t8/.usage/polish"
cat > "$_t8/.usage/polish/daily.json" <<'EOF'
{"date":"2026-11-16","total_tokens":3400,"total_cost_usd":0.5,"by_cli":{"claude":{"tokens":1365,"cost_usd":0.1},"muse":{"tokens":1670,"cost_usd":0.2},"opencode":{"tokens":125,"cost_usd":0.15}},"prompt":"$0.50 | 3K tok"}
EOF
cat > "$_t8/.usage/polish/pi.json" <<'EOF'
{"cli":"pi","date":"2026-11-16","total_tokens":240,"total_cost_usd":0.05,"input_tokens":200,"output_tokens":30,"cache_read_tokens":10,"cache_write_tokens":0,"reasoning_tokens":0,"events":1}
EOF
_t8tab="$(HOME="$_t8" "$ROOT/bin/polish" tokens)"
# by_cli rows (3160) + merged pi.json (240) = 3400 with full per-cli keys.
echo "$_t8tab" | grep -q 'TOTAL.*3400' && echo "$_t8tab" | grep -q 'pi.*240.*\$0\.05' \
  && ok "tokens table merges per-cli file" || bad "tokens merge" "$_t8tab"
echo "$_t8tab" | grep -q 'claude.*\$0\.10' && ok "tokens table shows nonzero cost" || bad "tokens cost" "$_t8tab"
[ "$(HOME="$_t8" "$ROOT/bin/polish" tokens --prompt)" = '$0.50 | 3K tok' ] \
  && ok "tokens --prompt prints cache" || bad "tokens --prompt" "wrong output"
# codex prompt: incidental mention must stay silent; cwd field must fire.
mkdir -p "$_t8/bin" "$_t8/xsess" "$_t8/work/proj"
printf '#!/bin/sh\necho "codex-cli 0.0-test"\n' > "$_t8/bin/codex"; chmod +x "$_t8/bin/codex"
echo '{"transcript":"saw /tmp/nothing/unrelated.txt today"}' > "$_t8/xsess/r.jsonl"
(cd "$_t8/work/proj" && HOME="$_t8" CODEX_SESSIONS_DIR="$_t8/xsess" OPENCODE_DB="$_t8/no.db" \
  PATH="$_t8/bin:$PATH" "$ROOT/bin/polish" agents --prompt) | grep -q . \
  && bad "codex prompt FP" "fired on incidental mention" || ok "codex prompt ignores incidental mention"
(cd "$_t8/work/proj" && HOME="$_t8" CODEX_SESSIONS_DIR="$_t8/xsess" OPENCODE_DB="$_t8/no.db" \
  PATH="$_t8/bin:$PATH" "$ROOT/bin/polish" agents --prompt-quiet) \
  && bad "codex prompt-quiet FP" "exit 0 on incidental mention" || ok "codex prompt-quiet silent on FP"
echo "{\"cwd\":\"$_t8/work/proj\"}" > "$_t8/xsess/r.jsonl"
[ "$(cd "$_t8/work/proj" && HOME="$_t8" CODEX_SESSIONS_DIR="$_t8/xsess" OPENCODE_DB="$_t8/no.db" \
  PATH="$_t8/bin:$PATH" "$ROOT/bin/polish" agents --prompt)" = "codex" ] \
  && ok "codex prompt fires on cwd field" || bad "codex prompt" "silent on cwd field"
# installer: missing flag value + partial marker block.
_t8rc="$("$ROOT/installer/install.sh" --shell 2>&1)"; _t8code=$?
[ "$_t8code" = 1 ] && echo "$_t8rc" | grep -q "missing value" \
  && ok "installer missing value exits 1" || bad "installer missing value" "rc=$_t8code out=$_t8rc"
echo "$_t8rc" | grep -q "unbound variable" \
  && bad "installer missing value" "leaked unbound variable" || ok "installer missing value clean error"
printf '# >>> polish >>>\necho keepme\n' > "$_t8/.bashrc"
HOME="$_t8" SHELL=/bin/bash "$ROOT/installer/install.sh" --uninstall --shell bash --share "$_t8/share" >/dev/null 2>&1
grep -q "keepme" "$_t8/.bashrc" && ok "uninstall keeps file on partial block" || bad "uninstall partial block" "deleted user content"
# destructive / self-wipe / injection guards.
HOME="$_t8" "$ROOT/installer/install.sh" --share / --shell bash >/dev/null 2>&1 \
  && bad "share / refused" "exit 0" || ok "share / refused"
HOME="$_t8" "$ROOT/installer/install.sh" --share 'x";id;#' --shell bash 2>&1 | grep -q "must not contain" \
  && ok "share injection refused" || bad "share injection" "not refused"
HOME="$_t8" "$ROOT/installer/install.sh" --from "$ROOT" --share "$ROOT" --shell bash >/dev/null 2>&1 \
  && bad "self-wipe refused" "exit 0" || ok "self-wipe refused"
# symlinked starship config is left alone (target untouched).
mkdir -p "$_t8/.config" && echo "# linked" > "$_t8/real-starship.toml"
ln -s "$_t8/real-starship.toml" "$_t8/.config/starship.toml"
HOME="$_t8" SHELL=/bin/bash "$ROOT/installer/install.sh" --shell bash --from "$ROOT" >/dev/null 2>&1
[ -L "$_t8/.config/starship.toml" ] && grep -q "linked" "$_t8/real-starship.toml" \
  && ok "symlink starship untouched" || bad "symlink starship" "followed or replaced"
# orphan removal: created-from-nothing config removed iff still identical.
rm "$_t8/.config/starship.toml"
HOME="$_t8" SHELL=/bin/bash "$ROOT/installer/install.sh" --shell bash --from "$ROOT" >/dev/null 2>&1
[ ! -e "$_t8/.config/starship.toml.polish-bak" ] && cmp -s "$ROOT/starship.toml" "$_t8/.config/starship.toml" \
  && ok "orphan setup deployed without backup" || bad "orphan setup" "unexpected state"
HOME="$_t8" SHELL=/bin/bash "$ROOT/installer/install.sh" --uninstall --shell bash >/dev/null 2>&1
[ ! -e "$_t8/.config/starship.toml" ] && ok "orphan config removed" || bad "orphan config" "left behind"
HOME="$_t8" SHELL=/bin/bash "$ROOT/installer/install.sh" --shell bash --from "$ROOT" >/dev/null 2>&1
echo "# user edit" >> "$_t8/.config/starship.toml"
HOME="$_t8" SHELL=/bin/bash "$ROOT/installer/install.sh" --uninstall --shell bash >/dev/null 2>&1
grep -q "user edit" "$_t8/.config/starship.toml" && ok "edited orphan kept" || bad "edited orphan" "removed user edit"
# PREFIX with sed-special chars lands literally in the unit.
HOME="$_t8" SHELL=/bin/bash "$ROOT/installer/install.sh" --shell bash --from "$ROOT" --prefix "$_t8/a&b|c" --timer >/dev/null 2>&1
grep -qF "ExecStart=$_t8/a&b|c/polish-tokens-collect" "$_t8/.config/systemd/user/polish-tokens.service" \
  && ok "prefix sed-escaped" || bad "prefix sed" "ExecStart mangled"
# curl-pipe form: --help must work with $0=bash (no sed of $0).
bash -s -- --help < "$ROOT/installer/install.sh" 2>/dev/null | grep -q '^Usage:' \
  && ok "curl-pipe --help" || bad "curl-pipe --help" "broken under stdin"
rm -rf "$_t8"

echo "---"
echo "pass=$pass fail=$fail (incl. installer matrix)"
[ "$fail" = 0 ]
# === END installer-tests ===
