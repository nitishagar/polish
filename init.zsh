# Polish loader. Sourced from ~/.zshrc inside the marked # >>> polish >>> block.
# Order mirrors oh-my-zsh.sh: guard -> defaults -> fpath/compinit (once) ->
# libs -> plugins -> custom -> theme (starship, cached, last).
if [ -n "${POLISH_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
POLISH_LOADED=1

POLISH_DIR="${POLISH_DIR:-$HOME/.local/share/polish}"
POLISH_CUSTOM="${POLISH_CUSTOM:-$HOME/.polish-custom}"
POLISH_CACHE_DIR="${POLISH_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/polish}"
mkdir -p "$POLISH_CACHE_DIR"

# --- completion: exactly once -------------------------------------------
if [ -z "${POLISH_COMPINIT_DONE:-}" ]; then
  autoload -Uz compinit
  compinit -i -d "$POLISH_CACHE_DIR/zcompdump"
  POLISH_COMPINIT_DONE=1
fi

# --- antidote static bundle ----------------------------------------------
_polish_bundle="$POLISH_CACHE_DIR/zsh_plugins.zsh"
if command -v antidote >/dev/null 2>&1; then
  if [ ! -f "$_polish_bundle" ] || [ "$POLISH_DIR/.zsh_plugins.txt" -nt "$_polish_bundle" ]; then
    antidote bundle <"$POLISH_DIR/.zsh_plugins.txt" >"$_polish_bundle"
  fi
  # shellcheck disable=SC1090
  source "$_polish_bundle"
fi
unset _polish_bundle

# --- polish plugins --------------------------------------------------------
for _p in polish-ai polish-tokens polish-mux; do
  if [ -f "$POLISH_CUSTOM/plugins/$_p/$_p.plugin.zsh" ]; then
    # shellcheck disable=SC1090
    source "$POLISH_CUSTOM/plugins/$_p/$_p.plugin.zsh"
  elif [ -f "$POLISH_DIR/plugins/$_p/$_p.plugin.zsh" ]; then
    # shellcheck disable=SC1090
    source "$POLISH_DIR/plugins/$_p/$_p.plugin.zsh"
  fi
done
unset _p

# --- user custom (no fork needed) -------------------------------------------
# Null-glob for this file only: an existing-but-empty custom dir must not
# trip zsh's default NOMATCH. (Plain command, so bash -n still parses this.)
setopt localoptions nullglob 2>/dev/null || true
if [ -d "$POLISH_CUSTOM" ]; then
  for _f in "$POLISH_CUSTOM"/*.zsh; do
    [ -e "$_f" ] || continue
    # shellcheck disable=SC1090
    source "$_f"
  done
  unset _f
fi

# --- theme: starship, cached eval, last --------------------------------------
if command -v starship >/dev/null 2>&1; then
  _polish_starship_cache="$POLISH_CACHE_DIR/starship-init.zsh"
  if [ ! -f "$_polish_starship_cache" ]; then
    starship init zsh >"$_polish_starship_cache"
  fi
  # shellcheck disable=SC1090
  source "$_polish_starship_cache"
  unset _polish_starship_cache
fi

# --- fast node (prefer fnm over eager nvm) ------------------------------------
if command -v fnm >/dev/null 2>&1; then
  eval "$(fnm env --use-on-cd)"
fi

export PATH="$POLISH_DIR/bin:$PATH"
