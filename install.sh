#!/usr/bin/env bash
# Install my_claude under a prefix (default ~/.local). No sudo, no network.
set -euo pipefail

prefix="$HOME/.local"
seed=1
link=0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<USAGE
Usage: ./install.sh [--prefix DIR] [--no-agents] [--symlink]
  --prefix DIR  install under DIR (default: \$HOME/.local)
  --no-agents   do not copy example packs into the config directory
  --symlink     link bin/my_claude to this checkout instead of copying (for development)
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || { echo "--prefix needs a directory" >&2; exit 2; }; prefix="$2"; shift 2 ;;
    --no-agents) seed=0; shift ;;
    --symlink) link=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  echo "bash 4.4 or newer is required (found $BASH_VERSION)" >&2
  exit 1
fi

bindir="$prefix/bin"
libdir="$prefix/lib/my_claude"
sharedir="$prefix/share/my_claude/agents"
mkdir -p "$bindir" "$libdir" "$sharedir"

if [ "$link" -eq 1 ]; then
  ln -sf "$here/bin/my_claude" "$bindir/my_claude"
else
  install -m 755 "$here/bin/my_claude" "$bindir/my_claude"
fi
install -m 644 "$here/lib/my_claude/doctor.sh" "$libdir/doctor.sh"
for f in "$here"/agents/*.md; do
  install -m 644 "$f" "$sharedir/$(basename "$f")"
done
echo "Installed my_claude to $bindir/my_claude"

case ":$PATH:" in
  *":$bindir:"*) ;;
  *)
    echo
    echo "$bindir is not on your PATH. Add this line to ~/.bashrc or ~/.zshrc, then open a new shell:"
    echo "  export PATH=\"$bindir:\$PATH\""
    ;;
esac

if [ "$seed" -eq 1 ]; then
  echo
  MY_CLAUDE_CONFIG_DIR="${MY_CLAUDE_CONFIG_DIR:-}" "$bindir/my_claude" init
fi

echo
echo "Running my_claude doctor:"
"$bindir/my_claude" doctor || {
  echo
  echo "doctor reported failures. Fix them, then run: my_claude doctor"
  exit 1
}
