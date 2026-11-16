# polish-mux: multiplexer helpers. Shell layer holds autostart + aliases;
# real switching lives in native tmux/zellij/wezterm keybinds (Alt-hjkl).
if [ -z "${TMUX:-}" ] && [ "${POLISH_TMUX_AUTOSTART:-0}" = "1" ] && command -v tmux >/dev/null 2>&1; then
  if tmux has-session 2>/dev/null; then
    exec tmux attach-session
  else
    exec tmux new-session
  fi
fi

alias ta='tmux attach-session 2>/dev/null || tmux new-session'
alias tl='tmux list-sessions'
alias tn='tmux new-session -s'

# pw: switch to (or create) a window named for the current agent task.
pw() {
  if [ -z "${TMUX:-}" ]; then
    echo "pw: not inside tmux" >&2
    return 1
  fi
  local name="${1:-agent}"
  tmux new-window -n "$name" 2>/dev/null || tmux select-window -t "$name"
}
