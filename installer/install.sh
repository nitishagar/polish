#!/usr/bin/env bash
# polish installer: repo -> SHARE/polish, hook line -> shell rc (with backup).
# Usage:
#   install.sh [--shell bash|zsh] [--from DIR|URL] [--prefix DIR] [--share DIR]
#   install.sh --uninstall [--shell ...] [--share DIR]
# Env: POLISH_VERSION (default: main), GITHUB_REPO (default: nitishagar/polish)
set -u
REPO="${GITHUB_REPO:-nitishagar/polish}"
PREFIX="$HOME/.local/bin"
SHARE="$HOME/.local/share/polish"
SHELL_FLAVOR=""
FROM=""
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --shell) SHELL_FLAVOR="$2"; shift 2;;
    --from) FROM="$2"; shift 2;;
    --prefix) PREFIX="$2"; shift 2;;
    --share) SHARE="$2"; shift 2;;
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

if [ "$UNINSTALL" = 1 ]; then
  rm -rf "$SHARE"
  rm -f "$PREFIX/polish" "$PREFIX/polish-tokens-collect"
  if [ -n "$RC" ] && [ -f "$RC" ]; then
    if [ -f "$RC.polish-bak" ]; then
      cp "$RC.polish-bak" "$RC"
      echo "restored $RC from backup"
    else
      awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        $0 == b { skip=1; next } $0 == e { skip=0; next } !skip { print }
      ' "$RC" > "$RC.tmp" && mv "$RC.tmp" "$RC"
      echo "removed polish block from $RC"
    fi
  fi
  echo "uninstalled (token cache left in ~/.usage; see docs/uninstall.html)"
  exit 0
fi

# --- install ---
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
srcdir=""
if [ -n "$FROM" ] && [ -d "$FROM" ]; then
  srcdir="$FROM"
elif [ -n "$FROM" ]; then
  curl -fsSL -o "$tmpdir/polish.tar.gz" "$FROM" || { echo "download failed: $FROM" >&2; exit 1; }
  mkdir -p "$tmpdir/src" && tar -xzf "$tmpdir/polish.tar.gz" -C "$tmpdir/src"
  srcdir="$(find "$tmpdir/src" -maxdepth 2 -name init.zsh -printf '%h' -quit)"
  [ -n "$srcdir" ] || { echo "archive missing init.zsh" >&2; exit 1; }
elif [ -f "./init.zsh" ]; then
  srcdir="."
else
  version="${POLISH_VERSION:-main}"
  url="https://github.com/$REPO/archive/refs/heads/$version.tar.gz"
  curl -fsSL -o "$tmpdir/polish.tar.gz" "$url" || { echo "download failed: $url" >&2; exit 1; }
  mkdir -p "$tmpdir/src" && tar -xzf "$tmpdir/polish.tar.gz" -C "$tmpdir/src"
  srcdir="$(find "$tmpdir/src" -maxdepth 2 -name init.zsh -printf '%h' -quit)"
  [ -n "$srcdir" ] || { echo "archive missing init.zsh" >&2; exit 1; }
fi

rm -rf "$SHARE"
mkdir -p "$SHARE"
cp -r "$srcdir"/. "$SHARE"/
chmod +x "$SHARE"/bin/* "$SHARE"/installer/install.sh
mkdir -p "$PREFIX"
ln -sf "$SHARE/bin/polish" "$PREFIX/polish"
ln -sf "$SHARE/bin/polish-tokens-collect" "$PREFIX/polish-tokens-collect"
echo "installed $SHARE (linked into $PREFIX)"

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
