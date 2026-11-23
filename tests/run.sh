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

# 9. usage-dir contract: all four cache readers agree (set and unset).
_t9="$(mktemp -d)"
mkdir -p "$_t9/home/.usage/polish" "$_t9/alt" "$_t9/empty"
printf '%s' '{"date":"2026-11-16","total_tokens":100,"total_cost_usd":0.01,"by_cli":{},"prompt":"$0.01 | 100 tok"}' > "$_t9/home/.usage/polish/daily.json"
printf '%s' '{"date":"2026-11-16","total_tokens":200000,"total_cost_usd":0.02,"by_cli":{},"prompt":"$0.02 | 200K tok"}' > "$_t9/alt/daily.json"
[ "$(HOME="$_t9/home" POLISH_USAGE_DIR="$_t9/alt" "$ROOT/bin/polish" tokens --prompt)" = '$0.02 | 200K tok' ] \
  && ok "usage-dir honored by polish tokens" || bad "usage-dir polish" "override ignored"
[ "$(HOME="$_t9/home" "$ROOT/bin/polish" tokens --prompt)" = '$0.01 | 100 tok' ] \
  && ok "usage-dir default unchanged" || bad "usage-dir default" "changed"
HOME="$_t9/home" POLISH_USAGE_DIR="$_t9/alt" bash -c 'source "$0" && polish_tokens_today' \
  "$ROOT/plugins/polish-tokens/polish-tokens.plugin.zsh" 2>/dev/null | grep -q '200K tok' \
  && ok "usage-dir honored by pt" || bad "usage-dir pt" "override ignored"
_POLISH_T9="$_t9" _POLISH_TOML="$ROOT/starship.toml" python3 - <<'PYEOF' 2>/dev/null \
  && ok "usage-dir honored by starship modules" || bad "starship usage-dir" "see failures above"
import os, subprocess, sys, tomllib
t9 = os.environ["_POLISH_T9"]
cfg = tomllib.load(open(os.environ["_POLISH_TOML"], "rb"))
fails = []
def check(name, cond):
    print(("ok   usage-dir starship %s" % name) if cond else ("FAIL usage-dir starship %s" % name))
    if not cond:
        fails.append(name)
def sh(cmd, env):
    e = dict(os.environ); e.update(env)
    p = subprocess.run(["sh", "-c", cmd], env=e, capture_output=True, text=True)
    return p.returncode, p.stdout.strip()
home = os.path.join(t9, "home"); alt = os.path.join(t9, "alt")
base = {"HOME": home}
when = cfg["custom"]["polish_tokens"]["when"]
check("when-override-hit", sh(when, {**base, "POLISH_USAGE_DIR": alt})[0] == 0)
check("when-override-wins", sh(when, {**base, "POLISH_USAGE_DIR": os.path.join(t9, "empty")})[0] == 1)
check("when-default-hit", sh(when, base)[0] == 0)
spaced = os.path.join(t9, "alt space"); os.makedirs(spaced, exist_ok=True)
open(os.path.join(spaced, "daily.json"), "w").write('{"prompt":"s"}')
check("when-space-path", sh(when, {**base, "POLISH_USAGE_DIR": spaced})[0] == 0)
ctxwhen = cfg["custom"]["polish_context"]["when"]
check("ctx-when-matches", ctxwhen == when)
check("ctx-when-override-hit", sh(ctxwhen, {**base, "POLISH_USAGE_DIR": alt})[0] == 0)
ctx = cfg["custom"]["polish_context"]["command"]
check("ctx-override", sh(ctx, {**base, "POLISH_USAGE_DIR": alt}) == (0, "100%"))
check("ctx-default", sh(ctx, base) == (0, "0%"))
stub = os.path.join(t9, "stubbin"); os.makedirs(stub, exist_ok=True)
sp = os.path.join(stub, "polish")
open(sp, "w").write('#!/bin/sh\nif [ "$STUB_OUT" = "empty" ]; then exit 0; else echo "$STUB_OUT"; fi\n')
os.chmod(sp, 0o755)
agent = cfg["custom"]["polish_agent"]["command"]
senv = {"PATH": stub + ":" + os.environ.get("PATH", ""), "STUB_OUT": "empty"}
check("agent-snippet-empty-hides", sh(agent, senv) == (1, ""))
senv["STUB_OUT"] = "pi"
check("agent-snippet-token", sh(agent, senv) == (0, "pi"))
sys.exit(1 if fails else 0)
PYEOF
grep -q "log parsing never happens" "$ROOT/starship.toml" \
  && bad "never-parses narrowed" "overclaim still present" || ok "never-parses narrowed"
grep -q 'nonzero' "$ROOT/starship.toml" \
  && ok "nonzero fact preserved" || bad "nonzero fact" "lost in rewrite"
grep -q 'zellij/wezterm native configs' "$ROOT/README.md" \
  && bad "README mux" "stale claim" || ok "README mux fixed"
grep -q 'POLISH_USAGE_DIR' "$ROOT/lib/prices.json" \
  && ok "prices note override path" || bad "prices note" "hardcoded path"
rm -rf "$_t9"

# 10. Phase 2 (HC2): publish integrity + cache regen + lint directives.
cmp -s "$ROOT/installer/install.sh" "$ROOT/docs/install.sh" \
  && ok "installer copy in sync" || bad "installer drift" "docs/install.sh differs"
_t10="$(mktemp -d)"
tar -czf "$_t10/polish.tar.gz" -C "$ROOT" --exclude=.git . 2>/dev/null
_t10sum="$(sha256sum "$_t10/polish.tar.gz" | awk '{print $1}')"
_t10home="$_t10/home"; mkdir -p "$_t10home"; echo "# rc" > "$_t10home/.bashrc"
HOME="$_t10home" SHELL=/bin/bash POLISH_TARBALL_SHA256=deadbeef \
  "$ROOT/installer/install.sh" --shell bash --from "file://$_t10/polish.tar.gz" --share "$_t10home/share" >/dev/null 2>&1
[ "$?" != 0 ] && [ ! -e "$_t10home/share" ] \
  && ok "checksum mismatch aborts pre-write" || bad "checksum mismatch" "installed despite bad hash"
HOME="$_t10home" SHELL=/bin/bash POLISH_TARBALL_SHA256="$_t10sum" \
  "$ROOT/installer/install.sh" --shell bash --from "file://$_t10/polish.tar.gz" --share "$_t10home/share" >/dev/null 2>&1 \
  && ok "checksum accept installs" || bad "checksum accept" "rejected good hash"
rm -rf "$_t10home/share"
HOME="$_t10home" SHELL=/bin/bash "$ROOT/installer/install.sh" --shell bash --from "file://$_t10/polish.tar.gz" --share "$_t10home/share" 2>"$_t10/warn.log" >/dev/null
grep -q -i "unverified" "$_t10/warn.log" \
  && ok "unverified download warns" || bad "unverified warning" "silent"
# shasum fallback: a PATH with every tool EXCEPT sha256sum (macOS shape).
mkdir -p "$_t10/stubbin"
for _t in /usr/bin/* /bin/*; do
  _b="$(basename "$_t")"
  [ "$_b" = "sha256sum" ] && continue
  [ -e "$_t10/stubbin/$_b" ] || ln -s "$_t" "$_t10/stubbin/$_b" 2>/dev/null
done
rm -f "$_t10/stubbin/shasum"  # never write through a real-shasum symlink
printf '#!/usr/bin/env python3\nimport hashlib,sys\nprint(hashlib.sha256(open(sys.argv[-1],"rb").read()).hexdigest())\n' > "$_t10/stubbin/shasum" && chmod +x "$_t10/stubbin/shasum"
rm -rf "$_t10home/share"
HOME="$_t10home" SHELL=/bin/bash POLISH_TARBALL_SHA256="$_t10sum" PATH="$_t10/stubbin" \
  "$ROOT/installer/install.sh" --shell bash --from "file://$_t10/polish.tar.gz" --share "$_t10home/share" >/dev/null 2>&1 \
  && ok "shasum fallback works" || bad "shasum fallback" "broken"
python3 - "$_t10/evil.tar.gz" <<'PYEOF'
import io, sys, tarfile
t = tarfile.open(sys.argv[1], "w:gz")
i = tarfile.TarInfo("../evil.sh"); d = b"echo pwned"
i.size = len(d); t.addfile(i, io.BytesIO(d)); t.close()
PYEOF
rm -rf "$_t10home/share"
HOME="$_t10home" SHELL=/bin/bash "$ROOT/installer/install.sh" --shell bash --from "file://$_t10/evil.tar.gz" --share "$_t10home/share" >/dev/null 2>&1
[ "$?" != 0 ] && [ ! -e "$_t10home/share" ] \
  && ok "tar-slip tarball rejected" || bad "tar-slip" "unsafe members extracted"
mkdir -p "$_t10/rgbin" "$_t10/rgcache"
printf '#!/bin/sh\necho "# new init"\n' > "$_t10/rgbin/starship"; chmod +x "$_t10/rgbin/starship"
echo "# stale cache" > "$_t10/rgcache/starship-init.zsh"
touch -d '2020-01-01' "$_t10/rgcache/starship-init.zsh"
PATH="$_t10/rgbin:/usr/bin:/bin" POLISH_DIR="$ROOT" POLISH_CUSTOM="$_t10/nonexistent" \
  POLISH_CACHE_DIR="$_t10/rgcache" POLISH_TMUX_AUTOSTART=0 bash -c 'source "$0"' "$ROOT/init.zsh" 2>/dev/null
grep -q 'new init' "$_t10/rgcache/starship-init.zsh" \
  && ok "starship cache regenerates on newer binary" || bad "starship regen" "stale cache kept"
printf '#!/bin/sh\nexit 1\n' > "$_t10/rgbin/starship"
echo "# good cache" > "$_t10/rgcache/starship-init.zsh"; touch -d '2020-01-01' "$_t10/rgcache/starship-init.zsh"
PATH="$_t10/rgbin:/usr/bin:/bin" POLISH_DIR="$ROOT" POLISH_CUSTOM="$_t10/nonexistent" \
  POLISH_CACHE_DIR="$_t10/rgcache" POLISH_TMUX_AUTOSTART=0 bash -c 'source "$0"' "$ROOT/init.zsh" 2>/dev/null
grep -q 'good cache' "$_t10/rgcache/starship-init.zsh" \
  && ok "failed regen keeps good cache" || bad "regen clobber" "cache destroyed"
for _scf in init.zsh plugins/polish-ai/polish-ai.plugin.zsh plugins/polish-mux/polish-mux.plugin.zsh plugins/polish-tokens/polish-tokens.plugin.zsh; do
  grep -q '^# shellcheck shell=bash' "$ROOT/$_scf" \
    && ok "directive $_scf" || bad "directive $_scf" "missing shell directive"
done
rm -rf "$_t10"

# 11. Phase 3 (HC3): prompt trust pins + hang guard.
# Measured budget (2026-11-22, this machine): agents --prompt over 2001 muse
# session lines completes in ~0.04s. The guard below (timeout 10) is a hang
# detector, not a perf assertion — CI variance forbids a tight threshold.
_t11="$(mktemp -d)"
mkdir -p "$_t11/home/.local/share/muse/sessions/big" "$_t11/home/work"
for _i in $(seq 1 2000); do
  echo "{\"payload\":{\"event\":{\"kind\":\"status\",\"msg\":\"stale $_i\"}}}"
done > "$_t11/home/.local/share/muse/sessions/big/session.jsonl"
echo "{\"cwd\":\"$_t11/home/work\",\"payload\":{\"event\":{\"kind\":\"model_completed\"}}}" >> "$_t11/home/.local/share/muse/sessions/big/session.jsonl"
if command -v timeout >/dev/null 2>&1; then
  _t11out="$(cd "$_t11/home/work" && HOME="$_t11/home" MUSE_SESSIONS_DIR="$_t11/home/.local/share/muse/sessions" \
    OPENCODE_DB="$_t11/no.db" timeout 10 "$ROOT/bin/polish" agents --prompt)" && _t11rc=0 || _t11rc=$?
  [ "$_t11rc" = 0 ] && [ "$_t11out" = "muse" ] \
    && ok "prompt hang guard" || bad "prompt hang guard" "rc=$_t11rc out=$_t11out"
  # Breadth probe: file-count traversal WITHOUT a token expectation (a lone
  # match in 500 files would usually fall past `head -50`, so expecting a
  # token here would be order-flaky by construction).
  for _i in $(seq 1 500); do
    mkdir -p "$_t11/home/.local/share/muse/breadth/d$_i"
    echo "{\"payload\":{\"event\":{\"kind\":\"status\"}}}" > "$_t11/home/.local/share/muse/breadth/d$_i/session.jsonl"
  done
  (cd "$_t11/home/work" && HOME="$_t11/home" MUSE_SESSIONS_DIR="$_t11/home/.local/share/muse" \
    OPENCODE_DB="$_t11/no.db" timeout 30 "$ROOT/bin/polish" agents --prompt >/dev/null 2>&1) \
    && ok "prompt traversal breadth" || bad "prompt traversal breadth" "stalled on 500 files"
else
  ok "prompt hang guard (skipped: no timeout)"
  ok "prompt traversal breadth (skipped: no timeout)"
fi
mkdir -p "$_t11/absbin"
printf '#!/bin/sh\necho "COLLECTOR-INVOKED"; exit 3\n' > "$_t11/absbin/polish-tokens-collect" && chmod +x "$_t11/absbin/polish-tokens-collect"
mkdir -p "$_t11/abshome/.usage/polish"
printf '%s' '{"date":"2026-11-16","total_tokens":1,"total_cost_usd":0.0,"by_cli":{},"prompt":"p"}' > "$_t11/abshome/.usage/polish/daily.json"
_absout="$(cd "$_t11" && HOME="$_t11/abshome" OPENCODE_DB="$_t11/no.db" PATH="$_t11/absbin:/usr/bin:/bin" \
  sh -c '"$0" tokens --prompt; "$0" agents --prompt-quiet' "$ROOT/bin/polish" 2>&1)"
echo "$_absout" | grep -q COLLECTOR-INVOKED \
  && bad "prompt never collects" "collector invoked" || ok "prompt never collects"
grep -q 'mode=ro' "$ROOT/bin/polish" \
  && ok "prompt opencode read-only pinned" || bad "prompt opencode ro" "mode=ro missing"
mkdir -p "$_t11/emptybin" "$_t11/dochome"
_bash="$(command -v bash)"
PATH="$_t11/emptybin" HOME="$_t11/dochome" "$_bash" "$ROOT/bin/polish" doctor >"$_t11/doctor.out" 2>&1; _docrc=$?
[ "$_docrc" = 0 ] && grep -q -- '--- agent CLIs ---' "$_t11/doctor.out" \
  && grep -q 'missing zsh' "$_t11/doctor.out" && grep -q 'missing claude' "$_t11/doctor.out" \
  && grep -q 'empty.*daily.json' "$_t11/doctor.out" \
  && ok "doctor rc=0 under missing tools" || bad "doctor shape" "rc=$_docrc"
rm -rf "$_t11"

# 12. Output formatting: color controls, plain machine paths, cx thresholds.
_t12="$(mktemp -d)"
mkdir -p "$_t12/home/.usage/polish"
printf '%s' '{"date":"2026-11-16","total_tokens":190000,"total_cost_usd":1.5,"by_cli":{"claude":{"tokens":190000,"cost_usd":1.5}},"prompt":"$1.50 | 190K tok"}' > "$_t12/home/.usage/polish/daily.json"
for _cmd in "doctor" "agents" "tokens" "mux" "theme"; do
  HOME="$_t12/home" POLISH_COLOR=always "$ROOT/bin/polish" $_cmd 2>/dev/null | grep -q $'\e' \
    && ok "color always: $_cmd" || bad "color always: $_cmd" "no escape codes"
  HOME="$_t12/home" POLISH_COLOR=never "$ROOT/bin/polish" $_cmd 2>/dev/null | grep -q $'\e' \
    && bad "color never: $_cmd" "leaked escapes" || ok "color never: $_cmd"
  HOME="$_t12/home" NO_COLOR=1 POLISH_COLOR=always "$ROOT/bin/polish" $_cmd 2>/dev/null | grep -q $'\e' \
    && bad "NO_COLOR: $_cmd" "leaked escapes" || ok "NO_COLOR: $_cmd"
done
HOME="$_t12/home" POLISH_COLOR=always "$ROOT/bin/polish" tokens --prompt 2>/dev/null | grep -q $'\e' \
  && bad "prompt plain: tokens" "leaked escapes" || ok "prompt plain: tokens"
mkdir -p "$_t12/proj"
_enc="$(printf '%s' "$_t12/proj" | tr '/' '-')"
mkdir -p "$_t12/home/.claude/projects/$_enc" && echo '{}' > "$_t12/home/.claude/projects/$_enc/s.jsonl"
(cd "$_t12/proj" && HOME="$_t12/home" OPENCODE_DB="$_t12/no.db" POLISH_COLOR=always "$ROOT/bin/polish" agents --prompt 2>/dev/null) | grep -q '^claude$' \
  && ok "prompt plain: agents" || bad "prompt plain: agents" "leaked escapes or wrong token"
POLISH_COLOR=always "$ROOT/bin/polish" mux detect 2>/dev/null | grep -q $'\e' \
  && bad "prompt plain: mux" "leaked escapes" || ok "prompt plain: mux"
HOME="$_t12/home" POLISH_COLOR=always "$ROOT/bin/polish" theme show 2>/dev/null | grep -q $'\e' \
  && bad "prompt plain: theme" "leaked escapes" || ok "prompt plain: theme"
# cx threshold colors (Claude statusline convention: green<70, yellow<90, red).
_cx() { HOME="$1" POLISH_COLOR=always POLISH_CONTEXT_WINDOW="$2" bash -c 'source "$0" && polish_context_pct' \
  "$ROOT/plugins/polish-tokens/polish-tokens.plugin.zsh" 2>/dev/null; }
_cx "$_t12/home" 1000000 | grep -qF '[32m' && ok "cx green <70" || bad "cx green" "wrong color"
_cx "$_t12/home" 237500 | grep -qF '[33m' && ok "cx yellow 70-89" || bad "cx yellow" "wrong color"
_cx "$_t12/home" 200000 | grep -qF '[31m' && ok "cx red 90+" || bad "cx red" "wrong color"
HOME="$_t12/home" POLISH_COLOR=never bash -c 'source "$0" && polish_context_pct' \
  "$ROOT/plugins/polish-tokens/polish-tokens.plugin.zsh" 2>/dev/null | grep -q $'\e' \
  && bad "cx never" "leaked escapes" || ok "cx never plain"
rm -rf "$_t12"

echo "---"
echo "pass=$pass fail=$fail (incl. installer matrix)"
[ "$fail" = 0 ]
# === END installer-tests ===
