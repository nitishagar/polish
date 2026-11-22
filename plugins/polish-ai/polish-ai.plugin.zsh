# shellcheck shell=bash
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

# Guard: run a CLI only when installed, otherwise a quiet no-op with a hint.
# Every helper and alias below funnels through here so missing CLIs never
# produce "command not found" noise.
_polish_need() {
  command -v "$1" >/dev/null 2>&1 || { echo "$1: not installed" >&2; return 1; }
}

# --- claude: -c/--continue for the last session, --resume [id] to pick one --
claude_continue() {
  _polish_need claude || return 1
  claude --continue "$@"
}

claude_resume() {
  _polish_need claude || return 1
  if [ "$#" -gt 0 ]; then
    claude --resume "$@"
  else
    claude --resume
  fi
}

# --- muse: `muse resume [--last|<session-ref>]`, picker when bare ---------
muse_continue() {
  _polish_need muse || return 1
  muse resume --last "$@"
}

muse_resume() {
  _polish_need muse || return 1
  if [ "$#" -gt 0 ]; then
    muse resume "$@"
  else
    muse resume
  fi
}

# --- opencode: `opencode run -c` continues, `-s <id>` names a session ------
opencode_continue() {
  _polish_need opencode || return 1
  opencode run --continue "$@"
}

opencode_resume() {
  _polish_need opencode || return 1
  if [ "$#" -eq 0 ]; then
    echo "usage: opencode_resume <session-id> [message...]" >&2
    return 2
  fi
  opencode run --session "$@"
}

# --- pi: --continue for the last session, --resume picker / --session id ---
pi_continue() {
  _polish_need pi || return 1
  pi --continue "$@"
}

pi_resume() {
  _polish_need pi || return 1
  if [ "$#" -gt 0 ]; then
    pi --session "$@"
  else
    pi --resume
  fi
}

# --- safe aliases: no-op with a hint when the CLI is missing ----------------
# (Each alias calls a guarded helper, so it is safe to invoke anywhere.)
alias pcl='claude_continue'
alias pcr='claude_resume'
alias pml='muse_continue'
alias pmr='muse_resume'
alias poc='opencode_continue'
alias por='opencode_resume'
alias ppi='pi_continue'
alias ppr='pi_resume'
