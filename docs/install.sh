#!/usr/bin/env bash
# polish installer: repo -> SHARE/polish, hook line -> shell rc (with backup),
# starship preset -> ~/.config/starship.toml (with backup), optional systemd
# user timer for polish-tokens-collect.
# Usage:
#   install.sh [--shell bash|zsh] [--from DIR|URL] [--prefix DIR] [--share DIR] [--timer]
#   install.sh --uninstall [--shell ...] [--share DIR]
# Env: POLISH_VERSION (default: main), GITHUB_REPO (default: nitishagar/polish)
set -u
REPO="${GITHUB_REPO:-nitishagar/polish}"
PREFIX="$HOME/.local/bin"
SHARE="$HOME/.local/share/polish"
SHELL_FLAVOR=""
FROM=""
UNINSTALL=0
TIMER=0

# need_value FLAG ARGC — die unless a value argument follows FLAG.
need_value() {
  if [ "$2" -lt 2 ]; then
    echo "missing value for $1" >&2
    exit 1
  fi
}
while [ $# -gt 0 ]; do
  case "$1" in
    --shell) need_value "$1" $#; SHELL_FLAVOR="$2"; shift 2;;
    --from) need_value "$1" $#; FROM="$2"; shift 2;;
    --prefix) need_value "$1" $#; PREFIX="$2"; shift 2;;
    --share) need_value "$1" $#; SHARE="$2"; shift 2;;
    --timer) TIMER=1; shift;;
    --uninstall) UNINSTALL=1; shift;;
    -h|--help) sed -n '2,7p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

detect_shell() {
  case "${SHELL:-}" in
    *zsh) echo zsh;;
    *) echo bash;;
  esac
}
[ -n "$SHELL_FLAVOR" ] || SHELL_FLAVOR="$(detect_shell)"
case "$SHELL_FLAVOR" in
  bash) RC="$HOME/.bashrc";;
  zsh) RC="$HOME/.zshrc";;
  *) echo "unsupported shell: $SHELL_FLAVOR (bash|zsh)" >&2; exit 1;;
esac

MARK_BEGIN="# >>> polish >>>"
MARK_END="# <<< polish <<<"
hook_line() {
  if [ "$SHELL_FLAVOR" = "zsh" ]; then
    echo "export POLISH_DIR=\"$SHARE\"; source \"\$POLISH_DIR/init.zsh\""
  else
    echo "export POLISH_DIR=\"$SHARE\"; export PATH=\"\$POLISH_DIR/bin:\$PATH\""
  fi
}

# Never remove /, $HOME, or an empty path (covers install + uninstall).
case "$SHARE" in
  ""|/|"$HOME") echo "refusing to use destructive share dir: '$SHARE'" >&2; exit 1;;
esac
# SHARE is interpolated into a double-quoted rc line: quotes/newlines would
# inject shell into every future login shell. Reject them outright.
case "$SHARE" in
  *\"*|*$'\n'*|*$'\r'*|*'$'*) echo "share dir must not contain quotes, newlines, or dollar signs" >&2; exit 1;;
esac

if [ "$UNINSTALL" = 1 ]; then
  # Snapshot the deployed preset before removing $SHARE: a config we created
  # from nothing (no backup) is removed again only if still byte-identical.
  _ucmpdir="$(mktemp -d)"
  _udeployed=""
  if [ -f "$SHARE/starship.toml" ]; then
    cp "$SHARE/starship.toml" "$_ucmpdir/deployed.toml" && _udeployed="$_ucmpdir/deployed.toml"
  fi
  rm -rf "$SHARE"
  rm -f "$PREFIX/polish" "$PREFIX/polish-tokens-collect"
  # timer units (stop first when a user systemd is reachable; never fatal)
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now polish-tokens.timer >/dev/null 2>&1 || true
  fi
  rm -f "$HOME/.config/systemd/user/polish-tokens.service" \
        "$HOME/.config/systemd/user/polish-tokens.timer"
  echo "removed polish-tokens timer units (if present)"
  # restore pre-install starship config when we backed one up; remove a
  # config we created only if untouched; otherwise leave the user's file.
  if [ -f "$HOME/.config/starship.toml.polish-bak" ]; then
    mv "$HOME/.config/starship.toml.polish-bak" "$HOME/.config/starship.toml"
    echo "restored $HOME/.config/starship.toml from backup"
  elif [ -n "$_udeployed" ] && [ -f "$HOME/.config/starship.toml" ] \
    && cmp -s "$_udeployed" "$HOME/.config/starship.toml"; then
    rm -f "$HOME/.config/starship.toml"
    echo "removed polish-installed starship config (was untouched, no backup existed)"
  fi
  rm -rf "$_ucmpdir"
  unset _ucmpdir _udeployed
  if [ -n "$RC" ] && [ -f "$RC" ]; then
    if [ -f "$RC.polish-bak" ]; then
      cp "$RC.polish-bak" "$RC"
      echo "restored $RC from backup"
    elif grep -qF "$MARK_BEGIN" "$RC" && grep -qF "$MARK_END" "$RC"; then
      # Both markers required: a lone MARK_BEGIN (truncated rc) must never
      # cause everything below it to be deleted.
      awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        $0 == b { skip=1; next } $0 == e { skip=0; next } !skip { print }
      ' "$RC" > "$RC.tmp" && mv "$RC.tmp" "$RC"
      echo "removed polish block from $RC"
    elif grep -qF "$MARK_BEGIN" "$RC" || grep -qF "$MARK_END" "$RC"; then
      echo "warning: partial polish block in $RC (missing marker); leaving file untouched" >&2
    else
      echo "no polish block in $RC"
    fi
  fi
  echo "uninstalled (token cache left in ~/.usage; see docs/uninstall.html)"
  exit 0
fi

# Deploy starship preset. Never overwrites blindly: an existing differing
# config is backed up to starship.toml.polish-bak first (existing backup kept).
deploy_starship() {
  _src="$1"
  [ -f "$_src/starship.toml" ] || return 0
  _cfg="$HOME/.config/starship.toml"
  mkdir -p "$HOME/.config"
  # A symlinked config belongs to someone else (dotfiles manager?): never
  # write through it, and never replace the link.
  if [ -L "$_cfg" ]; then
    if cmp -s "$_src/starship.toml" "$_cfg" 2>/dev/null; then
      echo "starship config already up to date (symlink)"
    else
      echo "note: $_cfg is a symlink; leaving it alone (merge the preset manually)" >&2
    fi
    return 0
  fi
  if [ -e "$_cfg" ]; then
    if cmp -s "$_src/starship.toml" "$_cfg"; then
      echo "starship config already up to date"
      return 0
    fi
    if [ ! -f "$_cfg.polish-bak" ]; then
      cp "$_cfg" "$_cfg.polish-bak"
      echo "backed up $_cfg to $_cfg.polish-bak"
    else
      echo "note: keeping existing backup $_cfg.polish-bak"
    fi
  fi
  cp "$_src/starship.toml" "$_cfg"
  echo "installed $_cfg"
}

# Install systemd user units for the token collector. Enabled via
# systemctl --user when available; installing the files never fails the run.
install_timer() {
  _src="$1"
  [ "$TIMER" = 1 ] || return 0
  _unitdir="$HOME/.config/systemd/user"
  if [ ! -f "$_src/installer/polish-tokens.service" ] || [ ! -f "$_src/installer/polish-tokens.timer" ]; then
    echo "error: installer unit files missing in $_src/installer" >&2
    return 1
  fi
  mkdir -p "$_unitdir"
  # Point ExecStart at the real install prefix (template uses the default).
  # Escape the replacement: a PREFIX containing | & or \ must not break sed.
  _esc_prefix="$(printf '%s' "$PREFIX" | sed 's/[|&\\]/\\&/g')"
  sed "s|%h/.local/bin/polish-tokens-collect|$_esc_prefix/polish-tokens-collect|" \
    "$_src/installer/polish-tokens.service" > "$_unitdir/polish-tokens.service"
  unset _esc_prefix
  cp "$_src/installer/polish-tokens.timer" "$_unitdir/polish-tokens.timer"
  echo "installed user units in $_unitdir"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    if systemctl --user enable --now polish-tokens.timer >/dev/null 2>&1; then
      echo "enabled polish-tokens.timer"
    else
      echo "note: systemctl --user enable failed (no user systemd?); units are in $_unitdir" >&2
    fi
  else
    echo "note: systemctl not found; units installed but not enabled" >&2
  fi
  return 0
}

# --- install ---
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
srcdir=""
if [ -n "$FROM" ] && [ -d "$FROM" ]; then
  srcdir="$FROM"
elif [ -n "$FROM" ]; then
  curl -fsSL -o "$tmpdir/polish.tar.gz" "$FROM" || { echo "download failed: $FROM" >&2; exit 1; }
  mkdir -p "$tmpdir/src" && tar -xzf "$tmpdir/polish.tar.gz" -C "$tmpdir/src"
  srcdir="$(find "$tmpdir/src" -maxdepth 2 -name init.zsh -exec dirname {} \; 2>/dev/null | head -1)"
  [ -n "$srcdir" ] || { echo "archive missing init.zsh" >&2; exit 1; }
elif [ -f "./init.zsh" ]; then
  srcdir="."
else
  version="${POLISH_VERSION:-main}"
  url="https://github.com/$REPO/archive/refs/heads/$version.tar.gz"
  curl -fsSL -o "$tmpdir/polish.tar.gz" "$url" || { echo "download failed: $url" >&2; exit 1; }
  mkdir -p "$tmpdir/src" && tar -xzf "$tmpdir/polish.tar.gz" -C "$tmpdir/src"
  srcdir="$(find "$tmpdir/src" -maxdepth 2 -name init.zsh -exec dirname {} \; 2>/dev/null | head -1)"
  [ -n "$srcdir" ] || { echo "archive missing init.zsh" >&2; exit 1; }
fi

# Never install from inside (or onto) the share dir itself (self-wipe).
if [ -d "$srcdir" ]; then
  _srcdir_abs="$(cd "$srcdir" && pwd)"
  case "$SHARE" in
    "$_srcdir_abs"|"$_srcdir_abs"/*) echo "--share must not equal or contain --from dir" >&2; exit 1;;
  esac
  case "$_srcdir_abs" in
    "$SHARE"|"$SHARE"/*) echo "--from dir must not equal or sit inside --share" >&2; exit 1;;
  esac
  unset _srcdir_abs
fi

rm -rf "$SHARE"
mkdir -p "$SHARE"
cp -r "$srcdir"/. "$SHARE"/
chmod +x "$SHARE"/bin/* "$SHARE"/installer/install.sh
mkdir -p "$PREFIX"
ln -sf "$SHARE/bin/polish" "$PREFIX/polish"
ln -sf "$SHARE/bin/polish-tokens-collect" "$PREFIX/polish-tokens-collect"
echo "installed $SHARE (linked into $PREFIX)"
deploy_starship "$srcdir"
install_timer "$srcdir" || exit 1

if [ "$SHELL_FLAVOR" = "zsh" ] && ! command -v zsh >/dev/null 2>&1; then
  echo "note: zsh not installed; polish needs zsh for the full setup" >&2
fi

touch "$RC"
if grep -qF "$MARK_BEGIN" "$RC"; then
  echo "hook already present in $RC"
else
  cp "$RC" "$RC.polish-bak"
  {
    echo "$MARK_BEGIN"
    hook_line
    echo "$MARK_END"
  } >> "$RC"
  echo "hooked $RC (backup: $RC.polish-bak)"
fi
echo "done. restart your shell, then run: polish doctor"
