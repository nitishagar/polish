#!/usr/bin/env bash
# tests/test-tokens.sh: fixtures + assertions for bin/polish-tokens-collect.
# Self-contained: builds a fake HOME, runs the collector against it, asserts
# outputs. Covers: claude-repeat dedupe, opencode msg+part count-once,
# cursor-incremental behavior, unknown-line counter, codex gating.
# bash + python3 stdlib only. Exits nonzero on any failure.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COLLECT="$ROOT/bin/polish-tokens-collect"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   tokens: $1"; }
bad() { fail=$((fail+1)); echo "FAIL tokens: $1: $2"; }
pyassert() { # $1=desc $2=python-script (exit 0 == pass)
  if python3 -c "$2" 2>/dev/null; then ok "$1"; else bad "$1" "assertion failed"; fi
}

fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
export HOME="$fake"
export CODEX_HOME="$fake/.codex-absent"   # phase 1-5: codex not installed
export POLISH_TODAY="2026-11-16"          # fixed date => stable assertions
export POLISH_PRICES_FILE="$ROOT/lib/prices.json"
U="$fake/.usage/polish"
ERR="$fake/stderr.log"
: > "$ERR"

# ---------------------------------------------------------- fixtures ---
mkdir -p "$fake/.claude/projects/slug1"
cat > "$fake/.claude/projects/slug1/sess.jsonl" <<'EOF'
{"type":"user","uuid":"u0","message":{"role":"user","content":"hi"}}
{"type":"assistant","uuid":"u1","requestedModel":"claude-haiku-4-5","message":{"model":"claude-haiku-4-5","id":"m1","role":"assistant","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}}}
{"type":"assistant","uuid":"u1","requestedModel":"claude-haiku-4-5","message":{"model":"claude-haiku-4-5","id":"m1","role":"assistant","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}}}
{"type":"assistant","uuid":"u2","message":{"model":"muse-spark-1.2","id":"m2","role":"assistant","usage":{"input_tokens":10,"output_tokens":5}}}
not json{{{
{"message":{"usage":"bogus"}}
EOF
# expected claude: m1 counted once (1350) + m2 (15) = 1365; unknown=2; deduped>=1

mkdir -p "$fake/.local/share/muse/sessions/2026/11/16/abc123"
mkdir -p "$fake/.local/share/muse/sessions/2026/11"
cat > "$fake/.local/share/muse/sessions/2026/11/16/abc123/session.jsonl" <<'EOF'
{"payload":{"event":{"kind":"model_completed","model":"muse-spark-1.3-contributor","duration_ms":100,"estimated_prompt_tokens":1500,"usage":{"input_tokens":1000,"output_tokens":100,"cache_read_tokens":500,"cache_write_tokens":0,"reasoning_tokens":20}}}}
{"payload":{"event":{"kind":"status","msg":"noise"}}}
{"payload":{"event":{"kind":"model_completed","model":"muse-spark-1.3-contributor","duration_ms":50,"usage":{"input_tokens":50,"output_tokens":10}}}}
garbage line here
EOF
cat > "$fake/.local/share/muse/sessions/2026/11/session.jsonl" <<'EOF'
{"payload":{"event":{"kind":"model_completed","model":"other-model","duration_ms":9,"usage":{"input_tokens":5,"output_tokens":5}}}}
EOF
# expected muse: 1600 + 60 + 10 = 1670 (both depths found); unknown=1

mkdir -p "$fake/.local/share/opencode"
python3 - "$fake/.local/share/opencode/opencode.db" <<'EOF'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INT, time_updated INT, data TEXT)")
con.execute("CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, data TEXT)")
def msg(role, **kw):
    d = {"role": role}; d.update(kw); return json.dumps(d)
con.execute("INSERT INTO message VALUES (?,?,?,?,?)", ("msg_a1", "s1", 1000, 1000,
    msg("assistant", tokens={"total": 4242, "input": 90, "output": 5, "reasoning": 5, "cache": {"write": 0, "read": 0}}, cost=0.001, modelID="test/model-x")))
con.execute("INSERT INTO message VALUES (?,?,?,?,?)", ("msg_a2", "s1", 1001, 1001,
    msg("assistant", tokens={"input": 20, "output": 10}, cost=0.0005, modelID="test/model-x")))
con.execute("INSERT INTO message VALUES (?,?,?,?,?)", ("msg_u1", "s1", 1002, 1002,
    msg("user")))
for pid, ptype in (("p1", "step-start"), ("p2", "text"), ("p3", "step-finish"), ("p4", "tool")):
    con.execute("INSERT INTO part VALUES (?,?,?)", (pid, "msg_a1", json.dumps({"type": ptype})))
con.commit(); con.close()
EOF
# expected opencode: (90+5) + (20+10) = 125 tokens, cost 0.0015.
# tokens.total is running context (4242 here), NOT summed; parts never counted;
# reasoning (5) is tracked separately, not added to the total (OpenAI-style).

mkdir -p "$fake/.pi/agent/sessions/--fake--"
cat > "$fake/.pi/agent/sessions/--fake--/sess.jsonl" <<'EOF'
{"type":"session","id":"s0"}
{"type":"message","id":"a1","message":{"role":"assistant","model":"pi-model","usage":{"input":200,"output":30,"cacheRead":10,"cacheWrite":0,"totalTokens":240,"cost":{"total":0.002}}}}
{"type":"message","id":"u1","message":{"role":"user"}}
{bad json
EOF
# expected pi: 240 tokens, cost 0.002; unknown=1

[ -x "$COLLECT" ] && ok "collector is executable" || bad "collector executable" "not +x"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['version']==1 and 'muse-spark-1.3' in d['models'] and 'muse-spark-1.2' in d['models']" "$ROOT/lib/prices.json" \
  && ok "prices map versioned with muse-spark-1.2/1.3" || bad "prices map" "invalid"

# ------------------------------------------------------------- run 1 ---
"$COLLECT" 2>>"$ERR" && ok "run1 exit 0" || bad "run1" "nonzero exit"
grep -q "Traceback" "$ERR" && bad "run1 stderr" "traceback" || ok "run1 no traceback"

pyassert "claude tokens 1365 after dedupe" "
import json,os; d=json.load(open(os.environ['HOME']+'/.usage/polish/claude.json'))
assert d['total_tokens']==1365, d; assert d['events']==2, d; assert d['deduped_lines']>=1, d"
pyassert "claude unknown_lines == 2" "
import json,os; d=json.load(open(os.environ['HOME']+'/.usage/polish/claude.json'))
assert d['unknown_lines']==2, d"
pyassert "claude cost uses price map (0.000735)" "
import json,os; d=json.load(open(os.environ['HOME']+'/.usage/polish/claude.json'))
assert abs(d['total_cost_usd']-0.000735) < 1e-9, d['total_cost_usd']"
pyassert "muse tokens 1670 across depths" "
import json,os; d=json.load(open(os.environ['HOME']+'/.usage/polish/muse.json'))
assert d['total_tokens']==1670, d; assert d['events']==3, d; assert d['unknown_lines']==1, d"
pyassert "muse suffix-strip pricing hit muse-spark-1.3" "
import json,os; d=json.load(open(os.environ['HOME']+'/.usage/polish/muse.json'))
assert 'muse-spark-1.3-contributor' in d['models'], d['models'].keys()"
pyassert "opencode msg+part counted once (125)" "
import json,os; d=json.load(open(os.environ['HOME']+'/.usage/polish/opencode.json'))
assert d['total_tokens']==125, d; assert abs(d['total_cost_usd']-0.0015) < 1e-12, d; assert d['events']==2, d
assert d['reasoning_tokens']==5, d"
pyassert "pi tokens 240 + reported cost" "
import json,os; d=json.load(open(os.environ['HOME']+'/.usage/polish/pi.json'))
assert d['total_tokens']==240, d; assert abs(d['total_cost_usd']-0.002) < 1e-12, d; assert d['unknown_lines']==1, d"
[ ! -f "$U/codex.json" ] && ok "codex absent skipped silently" || bad "codex gate" "codex.json written"
pyassert "daily.json aggregates (3400)" "
import json,os; d=json.load(open(os.environ['HOME']+'/.usage/polish/daily.json'))
assert d['date']=='2026-11-16', d
assert d['total_tokens']==3400, d
assert set(d['by_cli'])=={'claude','muse','opencode','pi'}, d['by_cli']
assert sum(v['tokens'] for v in d['by_cli'].values())==3400
assert d['prompt'] and 'tok' in d['prompt'], d['prompt']"
pyassert "cursors track per-file size/mtime/offset" "
import json,os
c=json.load(open(os.environ['HOME']+'/.usage/polish/cursors.json'))['files']
h=os.environ['HOME']
for p in (h+'/.claude/projects/slug1/sess.jsonl', h+'/.local/share/opencode/opencode.db'):
    assert p in c, p
    assert c[p]['size']>0 and c[p]['offset']>0 and 'mtime' in c[p], c[p]
import os as o
p=h+'/.claude/projects/slug1/sess.jsonl'
assert c[p]['offset']==o.path.getsize(p), (c[p]['offset'], o.path.getsize(p))"
[ "$(ls "$fake/.local/share/opencode" | tr '\n' ' ')" = "opencode.db " ] \
  && ok "opencode read-only (no WAL/SHM/journal writes)" \
  || bad "opencode read-only" "$(ls "$fake/.local/share/opencode")"

# ----------------------------------------------- run 2: no-change idle ---
"$COLLECT" 2>>"$ERR" && ok "run2 exit 0" || bad "run2" "nonzero exit"
pyassert "run2 adds nothing (cursor idle)" "
import json,os; d=json.load(open(os.environ['HOME']+'/.usage/polish/daily.json'))
assert d['total_tokens']==3400, d
c=json.load(open(os.environ['HOME']+'/.usage/polish/claude.json'))
assert c['events']==2 and c['total_tokens']==1365, c"

# -------------------------------------- run 3: append claude delta (m3) ---
M3='{"type":"assistant","uuid":"u3","message":{"model":"muse-spark-1.2","id":"m3","role":"assistant","usage":{"input_tokens":7,"output_tokens":3}}}'
echo "$M3" >> "$fake/.claude/projects/slug1/sess.jsonl"
"$COLLECT" 2>>"$ERR" && ok "run3 exit 0" || bad "run3" "nonzero exit"
pyassert "run3 counts only the delta (+10)" "
import json,os
c=json.load(open(os.environ['HOME']+'/.usage/polish/claude.json'))
assert c['total_tokens']==1375 and c['events']==3, c
d=json.load(open(os.environ['HOME']+'/.usage/polish/daily.json'))
assert d['total_tokens']==3410, d"

# ----------------------- run 4: repeat straddling cursor boundary (m3) ---
echo "$M3" >> "$fake/.claude/projects/slug1/sess.jsonl"
"$COLLECT" 2>>"$ERR" && ok "run4 exit 0" || bad "run4" "nonzero exit"
pyassert "run4 dedupes cross-boundary repeat" "
import json,os
c=json.load(open(os.environ['HOME']+'/.usage/polish/claude.json'))
assert c['total_tokens']==1375 and c['events']==3, c
assert c['deduped_lines']>=2, c"

# -------------------------------------- run 5: opencode incremental row ---
python3 - "$fake/.local/share/opencode/opencode.db" <<'EOF'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("INSERT INTO message VALUES (?,?,?,?,?)", ("msg_a3", "s1", 2000, 2000,
    json.dumps({"role": "assistant", "tokens": {"total": 77777, "input": 45, "output": 5}, "cost": 0.0002, "modelID": "test/model-x"})))
con.commit(); con.close()
EOF
"$COLLECT" 2>>"$ERR" && ok "run5 exit 0" || bad "run5" "nonzero exit"
pyassert "run5 opencode watermark counts new row only" "
import json,os; d=json.load(open(os.environ['HOME']+'/.usage/polish/opencode.json'))
assert d['total_tokens']==175 and d['events']==3, d"

# ------------------------------------------------ run 6: codex present ---
mkdir -p "$fake/.codex/sessions"
cat > "$fake/.codex/sessions/s.jsonl" <<'EOF'
{"type":"noise","payload":{}}
{"payload":{"model":"codex-mini","info":{"token_usage":{"input_tokens":40,"output_tokens":6}}}}
EOF
export CODEX_HOME="$fake/.codex"
"$COLLECT" 2>>"$ERR" && ok "run6 exit 0" || bad "run6" "nonzero exit"
pyassert "run6 codex parsed when installed" "
import json,os; d=json.load(open(os.environ['HOME']+'/.usage/polish/codex.json'))
assert d['total_tokens']==46 and d['events']==1, d"

# --------------------------------------- run 7: prices override wiring ---
mkdir -p "$fake/.usage2"
export POLISH_USAGE_DIR="$fake/.usage2"
export POLISH_PRICES_OVERRIDE="$fake/override.json"
echo '{"models":{"muse-spark-1.3":{"input":1000.0}}}' > "$fake/override.json"
"$COLLECT" 2>>"$ERR" && ok "run7 exit 0" || bad "run7" "nonzero exit"
pyassert "prices override inflates muse cost" "
import json,os; d=json.load(open(os.environ['HOME']+'/.usage2/muse.json'))
assert d['total_cost_usd'] > 1.0, d['total_cost_usd']"

# ---------------- run 8: redteam regressions (fresh usage dir, same HOME) ---
export POLISH_USAGE_DIR="$fake/.usage3"
export POLISH_PRICES_OVERRIDE="$fake/.usage3/prices.override.json"
mkdir -p "$fake/.local/share/muse/sessions/2026/11/17/dup1"
cat > "$fake/.local/share/muse/sessions/2026/11/17/dup1/session.jsonl" <<'EOF'
{"id":"e1","recorded_at":1000,"payload":{"event":{"kind":"model_completed","model":"m1","duration_ms":10,"usage":{"input_tokens":100,"output_tokens":10}}}}
{"id":"e2","recorded_at":1001,"payload":{"event":{"kind":"model_completed","model":"m1","duration_ms":10,"usage":{"input_tokens":100,"output_tokens":10}}}}
{"id":"e2","recorded_at":1001,"payload":{"event":{"kind":"model_completed","model":"m1","duration_ms":10,"usage":{"input_tokens":100,"output_tokens":10}}}}
EOF
cat >> "$fake/.claude/projects/slug1/sess.jsonl" <<'EOF'
{"type":"assistant","uuid":"u9","message":{"model":{"name":"object-model"},"id":"m9","role":"assistant","usage":{"input_tokens":3,"output_tokens":2}}}
EOF
"$COLLECT" 2>>"$ERR" && ok "run8 exit 0" || bad "run8" "nonzero exit"
pyassert "muse distinct-identical counted twice, repeat deduped" "
import json,os; d=json.load(open(os.environ['HOME']+'/.usage3/muse.json'))
assert d['events']==5, d  # 3 old + e1 + e2
assert d['total_tokens']==1670+220, d
assert d['deduped_lines']>=1, d"
pyassert "non-string model counted without crash" "
import json,os; d=json.load(open(os.environ['HOME']+'/.usage3/claude.json'))
assert d['events']==4, d  # m1, m2, m3, m9 (m1/m3 repeats deduped)
assert d['total_tokens']==1375+5, d"
"$COLLECT" 2>>"$ERR" && ok "run8b exit 0 (no cursor stall)" || bad "run8b" "nonzero exit"
pyassert "run8b adds nothing after object-model run" "
import json,os; d=json.load(open(os.environ['HOME']+'/.usage3/claude.json'))
assert d['events']==4 and d['total_tokens']==1380, d"

echo '{"models":[1]}' > "$fake/bad-override.json"
export POLISH_PRICES_OVERRIDE="$fake/bad-override.json"
export POLISH_USAGE_DIR="$fake/.usage4"
"$COLLECT" 2>>"$ERR" && ok "non-dict override tolerated" || bad "non-dict override" "nonzero exit"

"$COLLECT" --bogus >/dev/null 2>&1; _bogus_rc=$?
[ "$_bogus_rc" = 2 ] && ok "unknown flag exits 2" || bad "unknown flag" "exit=$_bogus_rc (want 2)"

# run via installer-style symlink: bundled price map must resolve (no warning)
mkdir -p "$fake/share/bin" "$fake/share/lib" "$fake/prefix" "$fake/home2"
cp "$COLLECT" "$fake/share/bin/polish-tokens-collect"
cp "$ROOT/lib/prices.json" "$fake/share/lib/prices.json"
ln -s "$fake/share/bin/polish-tokens-collect" "$fake/prefix/polish-tokens-collect"
HOME="$fake/home2" CODEX_HOME="$fake/home2/.codex-absent" POLISH_TODAY="2026-11-16" \
  env -u POLISH_PRICES_FILE -u POLISH_USAGE_DIR -u POLISH_PRICES_OVERRIDE \
  "$fake/prefix/polish-tokens-collect" >"$fake/link.out" 2>"$fake/link.err" \
  && ok "symlinked run exit 0" || bad "symlinked run" "nonzero exit"
grep -q "missing/invalid" "$fake/link.err" \
  && bad "symlinked prices" "fell back to built-in default" \
  || ok "symlinked prices resolve bundled map"

# ---------------- run 9: consistency + watermark edges (fresh usage dir) ---
export POLISH_USAGE_DIR="$fake/.usage5"
export POLISH_PRICES_OVERRIDE="$fake/.usage5/prices.override.json"
mkdir -p "$fake/m9/.local/share/muse/sessions/d" "$fake/m9/.codex/sessions"
export HOME="$fake/m9"
U9="$fake/.usage5"
cat > "$fake/m9/.local/share/muse/sessions/d/session.jsonl" <<'EOF'
{"payload":{"event":{"kind":"model_completed","model":"m1","usage":{}}}}
{"payload":{"event":{"kind":"model_completed","model":"m1","usage":{"input_tokens":10,"output_tokens":5}}}}
EOF
cat > "$fake/m9/.codex/sessions/c.jsonl" <<'EOF'
{"usage":{"input_tokens":"bogus"}}
{"usage":{"input_tokens":4,"output_tokens":1}}
EOF
export CODEX_HOME="$fake/m9/.codex"
"$COLLECT" 2>>"$ERR" && ok "run9 exit 0" || bad "run9" "nonzero exit"
pyassert "muse empty usage ignored (not unknown)" "
import json; d=json.load(open('$U9/muse.json'))
assert d['events']==1 and d['total_tokens']==15 and d['unknown_lines']==0, d"
pyassert "codex bad values counted unknown" "
import json; d=json.load(open('$U9/codex.json'))
assert d['events']==1 and d['total_tokens']==5 and d['unknown_lines']==1, d"

# opencode same-stamp volume + zero-stub fill + retouch, all in one db
export HOME="$fake"
python3 - "$fake/oc9.db" <<'EOF'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INT, time_updated INT, data TEXT)")
for i in range(3):
    con.execute("INSERT INTO message VALUES (?,?,?,?,?)", ("same%d" % i, "s", 5000, 5000,
        json.dumps({"role": "assistant", "tokens": {"input": 10, "output": 0}, "cost": 0.0, "modelID": "m"})))
con.execute("INSERT INTO message VALUES (?,?,?,?,?)", ("stub1", "s", 5000, 5000,
    json.dumps({"role": "assistant", "tokens": {"input": 0, "output": 0}, "cost": 0.0, "modelID": "m"})))
con.commit(); con.close()
EOF
export POLISH_USAGE_DIR="$fake/.usage9"
# point HOME so the collector finds our db: use a dedicated home tree
mkdir -p "$fake/h9/.local/share/opencode"
cp "$fake/oc9.db" "$fake/h9/.local/share/opencode/opencode.db"
export HOME="$fake/h9"
export CODEX_HOME="$fake/h9/.codex-absent"
"$COLLECT" 2>>"$ERR" && ok "run9b exit 0" || bad "run9b" "nonzero exit"
pyassert "same-stamp rows billed once each, stub skipped" "
import json; d=json.load(open('$fake/.usage9/opencode.json'))
assert d['events']==3 and d['total_tokens']==30, d"
# fill the stub WITHOUT bumping time_updated; retouch same0 with same content
python3 - "$fake/h9/.local/share/opencode/opencode.db" <<'EOF'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("UPDATE message SET data=? WHERE id='stub1'",
    (json.dumps({"role": "assistant", "tokens": {"input": 7, "output": 0}, "cost": 0.0, "modelID": "m"}),))
row = con.execute("SELECT data FROM message WHERE id='same0'").fetchone()[0]
con.execute("UPDATE message SET data=? WHERE id='same0'", (row,))
con.commit(); con.close()
EOF
"$COLLECT" 2>>"$ERR" && ok "run9c exit 0" || bad "run9c" "nonzero exit"
pyassert "stub fill counted, retouch not double-billed" "
import json; d=json.load(open('$fake/.usage9/opencode.json'))
assert d['events']==4 and d['total_tokens']==37, d"
pyassert "billed map bounded by stamp volume" "
import json
c=json.load(open('$fake/.usage9/cursors.json'))['files']
db='$fake/h9/.local/share/opencode/opencode.db'
assert set(c[db]['billed'])=={'same0','same1','same2','stub1'}, c[db]
assert c[db]['pending']==[], c[db]"

# cursor prune: delete a tracked log; foreign version: full rescan
export HOME="$fake"
export POLISH_USAGE_DIR="$fake/.usage5"
export POLISH_PRICES_OVERRIDE="$fake/.usage5/prices.override.json"
export CODEX_HOME="$fake/m9/.codex"
rm "$fake/m9/.local/share/muse/sessions/d/session.jsonl"
export HOME="$fake/m9"
"$COLLECT" 2>>"$ERR" && ok "run9d exit 0" || bad "run9d" "nonzero exit"
pyassert "deleted log cursor pruned" "
import json
c=json.load(open('$U9/cursors.json'))['files']
assert not any('muse/sessions/d/' in p for p in c), list(c)"
export POLISH_USAGE_DIR="$fake/.usage6"
mkdir -p "$fake/.usage6"
echo '{"version":99,"files":{}}' > "$fake/.usage6/cursors.json"
"$COLLECT" 2>>"$ERR" && ok "run9e exit 0" || bad "run9e" "nonzero exit"
pyassert "foreign cursor version triggers rescan" "
import json; d=json.load(open('$fake/.usage6/codex.json'))
assert d['events']==1 and d['total_tokens']==5, d
c=json.load(open('$fake/.usage6/cursors.json'))
assert c['version']==1, c"
export HOME="$fake"
export CODEX_HOME="$fake/.codex"

# ---------------- run 10: single-flight lock (failing-first for Phase 3) ---
export POLISH_USAGE_DIR="$fake/.usage10"
export POLISH_PRICES_OVERRIDE="$fake/.usage10/prices.override.json"
mkdir -p "$fake/m10/.claude/projects/slug"
export HOME="$fake/m10"
export CODEX_HOME="$fake/m10/.codex-absent"
cat > "$fake/m10/.claude/projects/slug/x.jsonl" <<'EOF'
{"type":"assistant","uuid":"l1","message":{"model":"m","id":"m1","role":"assistant","usage":{"input_tokens":10,"output_tokens":5}}}
EOF
"$COLLECT" 2>>"$ERR" && ok "run10 prime exit 0" || bad "run10 prime" "nonzero exit"
cat >> "$fake/m10/.claude/projects/slug/x.jsonl" <<'EOF'
{"type":"assistant","uuid":"l2","message":{"model":"m","id":"m2","role":"assistant","usage":{"input_tokens":7,"output_tokens":3}}}
EOF
_before="$(sha256sum "$fake/.usage10/claude.json" "$fake/.usage10/daily.json" "$fake/.usage10/cursors.json")"
python3 - "$fake/.usage10/.collect.lock" "$fake/.usage10/.ready" <<'PYEOF' &
import fcntl, os, sys, time
fh = open(sys.argv[1], "a")
fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
open(sys.argv[2], "w").write("held")
time.sleep(30)
PYEOF
_holder=$!
_ready_ok=0
for _i in $(seq 1 50); do
  [ -f "$fake/.usage10/.ready" ] && { _ready_ok=1; break; }
  sleep 0.1
done
[ "$_ready_ok" = 1 ] && ok "lock holder ready" || bad "lock holder" "never signaled"
"$COLLECT" >"$fake/lock.out" 2>"$fake/lock.err"; _lock_rc=$?
kill "$_holder" 2>/dev/null; wait "$_holder" 2>/dev/null
_after="$(sha256sum "$fake/.usage10/claude.json" "$fake/.usage10/daily.json" "$fake/.usage10/cursors.json")"
[ "$_lock_rc" = 0 ] && ok "contended run exits 0" || bad "contended run" "rc=$_lock_rc"
grep -q "another run is active, skipping" "$fake/lock.err" \
  && ok "contended run skip note" || bad "contended run" "no skip note (billed through?)"
[ "$_before" = "$_after" ] \
  && ok "contended run zero delta" || bad "contended run" "cache changed under lock"
rm -f "$fake/.usage10/.ready"

# run 11: legacy counted-list cursor migrates (pin; code already tolerates).
export POLISH_USAGE_DIR="$fake/.usage11"
mkdir -p "$fake/h11/.local/share/opencode"
python3 - "$fake/h11/.local/share/opencode/opencode.db" <<'EOF'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INT, time_updated INT, data TEXT)")
con.execute("INSERT INTO message VALUES (?,?,?,?,?)", ("old1", "s", 100, 100,
    json.dumps({"role": "assistant", "tokens": {"input": 10, "output": 5}, "cost": 0.0, "modelID": "m"})))
con.commit(); con.close()
EOF
export HOME="$fake/h11"
export CODEX_HOME="$fake/h11/.codex-absent"
"$COLLECT" 2>>"$ERR" && ok "run11 prime exit 0" || bad "run11 prime" "nonzero exit"
U11ROOT="$fake" python3 - <<'PYEOF'
import json, os
p = os.path.join(os.environ["U11ROOT"], ".usage11", "cursors.json")
c = json.load(open(p))
db = os.path.join(os.environ["U11ROOT"], "h11", ".local", "share", "opencode", "opencode.db")
cur = c["files"][db]
cur["counted"] = list(cur["billed"])
del cur["billed"]
json.dump(c, open(p, "w"))
PYEOF
touch "$fake/h11/.local/share/opencode/opencode.db"  # defeat fast path, no content change
"$COLLECT" 2>>"$ERR" && ok "run11 exit 0" || bad "run11" "nonzero exit"
pyassert "legacy counted list bills once and migrates" "
import json
d=json.load(open('$fake/.usage11/opencode.json'))
assert d['events']==1 and d['total_tokens']==15, d
c=json.load(open('$fake/.usage11/cursors.json'))['files']
db='$fake/h11/.local/share/opencode/opencode.db'
assert c[db]['billed']=={'old1':100}, c[db]"
export HOME="$fake"
export CODEX_HOME="$fake/.codex"

# ---------------- run 12: spinner gating (tty-only, forced, never) ---
export POLISH_USAGE_DIR="$fake/.usage12"
export POLISH_PRICES_OVERRIDE="$fake/.usage12/prices.override.json"
mkdir -p "$fake/m12/.claude/projects/slug"
export HOME="$fake/m12"
export CODEX_HOME="$fake/m12/.codex-absent"
# 200 files x 50 lines: enough scan work (~0.5s) to guarantee spinner ticks.
for _f in $(seq 1 200); do
  for _i in $(seq 1 50); do
    printf '{"type":"assistant","uuid":"u%s-%s","message":{"model":"m","id":"m%s-%s","role":"assistant","usage":{"input_tokens":10,"output_tokens":5}}}\n' "$_f" "$_i" "$_f" "$_i"
  done > "$fake/m12/.claude/projects/slug/x$_f.jsonl"
done
"$COLLECT" >"$fake/sp12.out" 2>"$fake/sp12.err" && ok "run12 exit 0" || bad "run12" "nonzero exit"
grep -q $'\r' "$fake/sp12.err" \
  && bad "spinner silent when piped" "carriage returns in stderr" || ok "spinner silent when piped"
python3 -c "import sys; sys.exit(0 if any('\u2800' <= c <= '\u28ff' for c in open('$fake/sp12.err').read()) else 1)" \
  && bad "spinner frames absent when piped" "braille found" || ok "spinner frames absent when piped"
export POLISH_USAGE_DIR="$fake/.usage12b"
POLISH_SPINNER=always POLISH_SPINNER_TICK_MS=5 "$COLLECT" >"$fake/sp12b.out" 2>"$fake/sp12b.err" && ok "spinner always exit 0" || bad "spinner always" "nonzero exit"
python3 -c "import sys; sys.exit(0 if any('\u2800' <= c <= '\u28ff' for c in open('$fake/sp12b.err').read()) else 1)" \
  && ok "spinner forced shows frames" || bad "spinner forced" "no braille frames"
grep -q 'date=.*sources=\[claude\]' "$fake/sp12b.err" \
  && ok "spinner summary intact" || bad "spinner summary" "missing"
# pty smoke: runs clean on a real terminal (skip when script(1) missing).
# Typescript output always goes to an explicit path (never ./typescript).
_script_form=""
if script -qec "true" "$fake/s-probe" >/dev/null 2>&1; then
  _script_form=linux
elif script -q "$fake/s-probe" true >/dev/null 2>&1; then
  _script_form=bsd
fi
if [ "$_script_form" = linux ]; then
  export POLISH_USAGE_DIR="$fake/.usage12c"
  script -qec "$COLLECT" "$fake/sp12c.typescript" >"$fake/sp12c.out" 2>"$fake/sp12c.err" \
    && ok "spinner pty smoke" || bad "spinner pty" "nonzero under pty"
elif [ "$_script_form" = bsd ]; then
  export POLISH_USAGE_DIR="$fake/.usage12c"
  script -q "$fake/sp12c.typescript" "$COLLECT" >"$fake/sp12c.out" 2>"$fake/sp12c.err" \
    && ok "spinner pty smoke" || bad "spinner pty" "nonzero under pty"
else
  ok "spinner pty smoke (skipped: no script)"
fi
unset POLISH_SPINNER
export HOME="$fake"
export CODEX_HOME="$fake/.codex"

echo "---"
echo "tokens: pass=$pass fail=$fail"
[ "$fail" = 0 ]
