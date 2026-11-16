# polish-tokens: token/cost prompt helpers. Reads ~/.usage/polish/*.json only.
# Parsing lives in bin/polish-tokens-collect (background poller), never here.
polish_tokens_today() {
  if [ -f "$HOME/.usage/polish/daily.json" ]; then
    cat "$HOME/.usage/polish/daily.json"
  else
    echo "no token data yet (run: polish-tokens-collect)"
    return 1
  fi
}
alias pt='polish_tokens_today'

# polish_context_pct: context-window burn % from the JSON cache ONLY.
# Prefers explicit context_tokens/context_window fields in daily.json when the
# collector writes them; else falls back to total_tokens (day cumulative) over
# POLISH_CONTEXT_WINDOW (default 200000). Day totals are cumulative, so the
# fallback is a burn-rate gauge ("a full window burned N% today"), not live
# context pressure. Never parses logs; missing cache exits nonzero.
# Output: one line, e.g.  ctx 12% (24,567/200,000)
polish_context_pct() {
  local usage_dir="${POLISH_USAGE_DIR:-$HOME/.usage/polish}"
  local daily="$usage_dir/daily.json"
  if [ ! -f "$daily" ]; then
    echo "no token data yet (run: polish-tokens-collect)" >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "polish_context_pct: python3 is required" >&2
    return 1
  fi
  _POLISH_CTX_DAILY="$daily" POLISH_CONTEXT_WINDOW="${POLISH_CONTEXT_WINDOW:-200000}" python3 - <<'PYEOF'
import json
import os
import sys

def fail(msg):
    sys.stderr.write("polish_context_pct: %s\n" % msg)
    sys.exit(1)

try:
    with open(os.environ["_POLISH_CTX_DAILY"], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception as exc:
    fail("token cache unreadable: daily.json (%s)" % exc)
if not isinstance(data, dict):
    fail("token cache unreadable: daily.json is not an object")

try:
    window_default = int(os.environ.get("POLISH_CONTEXT_WINDOW", "200000"))
except ValueError:
    window_default = 200000

tokens = data.get("context_tokens", data.get("total_tokens", 0))
window = data.get("context_window", window_default)
if not isinstance(tokens, (int, float)) or isinstance(tokens, bool):
    tokens = 0
if not isinstance(window, (int, float)) or isinstance(window, bool):
    window = window_default
tokens = max(0, int(tokens))
window = max(0, int(window))
if window <= 0:
    fail("context window is 0 (set POLISH_CONTEXT_WINDOW)")

pct = 100.0 * tokens / window
print("ctx %.0f%% (%s/%s)" % (pct, f"{tokens:,}", f"{window:,}"))
PYEOF
}
alias cx='polish_context_pct'
