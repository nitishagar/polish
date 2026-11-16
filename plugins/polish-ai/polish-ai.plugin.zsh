# polish-ai: agent CLI integration (claude, muse, codex, opencode, pi).
# Detection + launchers + session helpers. Codex paths stay gated behind
# an installed-check until codex exists on the machine.
polish_agents() {
  for c in claude muse codex opencode pi; do
    if command -v "$c" >/dev/null 2>&1; then
      echo "$c: $(command -v "$c")"
    else
      echo "$c: not installed"
    fi
  done
}

# Session-aware helpers land here (continue/resume wrappers per CLI).
alias pcl='claude --continue 2>/dev/null || claude'
