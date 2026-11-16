# polish-mux: multiplexer helpers. Shell layer holds autostart + aliases;
# real switching lives in native tmux/zellij/wezterm keybinds (Alt-hjkl).
#
# KEYBINDS (native; nothing to press before Alt- sequences):
#   tmux (see mux/tmux.conf):
#     Alt-h / Alt-j / Alt-k / Alt-l   select pane left/down/up/right (no prefix)
#     Alt-Shift-H/J/K/L               resize active pane 5 cells (no prefix)
#     Alt-o                           cycle to next pane (no prefix)
#     prefix + s                      built-in session tree picker
#     prefix + r                      reload mux/tmux.conf
#   zellij (defaults; see `zellij setup --dump-config` to confirm):
#     Alt-h/j/k/l                     move focus (when not locked)
#   wezterm (user wezterm.lua; polish ships no wezterm config yet):
#     Alt-h/j/k/l -> ActivatePaneDirection Left/Down/Up/Right
# Shell-side pickers below (mp) cover sessions; pane switching stays native.
# Autostart only in interactive shells (never under scp/rsync/CI), and attach
# atomically: `new-session -A` attaches when a session exists, else creates —
# no has-session/attach TOCTOU where a failed exec would kill the login shell.
if [[ -o interactive ]] && [ -z "${TMUX:-}" ] && [ "${POLISH_TMUX_AUTOSTART:-0}" = "1" ] && command -v tmux >/dev/null 2>&1; then
  exec tmux new-session -A
fi

alias ta='tmux attach-session 2>/dev/null || tmux new-session'
alias tl='tmux list-sessions'
alias tn='tmux new-session -s'

# --- zellij attach aliases (each fails cleanly when zellij is missing) ---
# za: attach to most recent session, else start a new one.
# zl: list sessions.  zn <name>: attach or create a named session.
alias za='zellij attach 2>/dev/null || zellij'
alias zl='zellij list-sessions 2>/dev/null || zellij ls 2>/dev/null'
# zn is a function (not an alias): attach-or-create without depending on
# any particular zellij flag spelling across versions.
zn() {
  if [ -z "${1:-}" ]; then echo "usage: zn <session-name>" >&2; return 1; fi
  command -v zellij >/dev/null 2>&1 || { echo "zn: zellij not installed" >&2; return 1; }
  zellij attach "$1" 2>/dev/null || zellij --session "$1"
}

# --- wezterm attach aliases (a wezterm multiplexing server must be running) ---
# wl: list panes/windows.  wa <domain>: attach to a wezterm domain/workspace.
alias wl='wezterm cli list 2>/dev/null || wezterm ls 2>/dev/null || echo "wezterm: no multiplexing server" >&2'
alias wa='wezterm connect'

# pw: switch to (or create) a window named for the current agent task.
pw() {
  if [ -z "${TMUX:-}" ]; then
    echo "pw: not inside tmux" >&2
    return 1
  fi
  local name="${1:-agent}"
  tmux new-window -n "$name" 2>/dev/null || tmux select-window -t "$name"
}

# mux_pick: session picker. Usage: mux_pick [tmux|zellij] (default tmux).
# Uses fzf when present, else prints a numbered list and reads one number.
# Inside tmux it switches the client; outside it attaches. Never nests zellij.
mux_pick() {
  local backend="${1:-tmux}"
  case "$backend" in
    tmux|t) _mux_pick_tmux ;;
    zellij|z) _mux_pick_zellij ;;
    *) echo "mux_pick: usage: mux_pick [tmux|zellij]" >&2; return 1 ;;
  esac
}

# _mux_choose: pick one line from newline-separated $1 via fzf or numbered list.
# Prints the choice on stdout; prompts go to stderr. Nonzero on cancel/empty.
_mux_choose() {
  local items="$1" prompt="$2" choice="" pick="" line="" i=""
  if [ -z "$items" ]; then
    return 1
  fi
  if command -v fzf >/dev/null 2>&1; then
    choice="$(printf '%s\n' "$items" | fzf --prompt="$prompt> " --height=40% --reverse --select-1 --exit-0)" || return 1
    [ -n "$choice" ] || return 1
    printf '%s\n' "$choice"
    return 0
  fi
  # Numbered fallback (portable bash+zsh; indexed by line, not array).
  i=1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '  %d) %s\n' "$i" "$line"
    i=$((i + 1))
  done <<< "$items" >&2
  printf 'pick # (0 to quit): ' >&2
  IFS= read -r pick || return 1
  case "$pick" in
    ''|*[!0-9]*) echo "mux_pick: cancelled" >&2; return 1 ;;
  esac
  if [ "$pick" -eq 0 ]; then
    return 1
  fi
  choice="$(printf '%s\n' "$items" | sed -n "${pick}p")"
  [ -n "$choice" ] || { echo "mux_pick: out of range" >&2; return 1; }
  printf '%s\n' "$choice"
}

_mux_pick_tmux() {
  command -v tmux >/dev/null 2>&1 || { echo "mux_pick: tmux not installed" >&2; return 1; }
  local sessions choice
  sessions="$(tmux list-sessions -F '#S' 2>/dev/null)" || { echo "mux_pick: no tmux sessions" >&2; return 1; }
  [ -n "$sessions" ] || { echo "mux_pick: no tmux sessions" >&2; return 1; }
  choice="$(_mux_choose "$sessions" "tmux")" || return 1
  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "$choice"
  else
    tmux attach-session -t "$choice"
  fi
}

_mux_pick_zellij() {
  command -v zellij >/dev/null 2>&1 || { echo "mux_pick: zellij not installed" >&2; return 1; }
  local sessions choice
  # First column is the session name. Drop only an exact SESSION header cell
  # and a lone "No" (from "No active sessions ..."); anything broader eats
  # legit names like "notes" or "session-info".
  sessions="$(zellij list-sessions 2>/dev/null | awk 'NF && $1 != "SESSION" {print $1}' | grep -v -x -i 'no' || true)"
  [ -n "$sessions" ] || { echo "mux_pick: no zellij sessions" >&2; return 1; }
  choice="$(_mux_choose "$sessions" "zellij")" || return 1
  zellij attach "$choice"
}

alias mp='mux_pick'
