#!/usr/bin/env bash
# Install my_claude under a prefix (default ~/.local). No sudo.
set -euo pipefail

prefix="$HOME/.local"
deps=1
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<USAGE
Usage: ./install.sh [--prefix DIR] [--no-deps]
  --prefix DIR  install under DIR (default: \$HOME/.local)
  --no-deps     do not create the Python environment (run 'my_claude install-deps' later)
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || { echo "--prefix needs a directory" >&2; exit 2; }; prefix="$2"; shift 2 ;;
    --no-deps) deps=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  echo "bash 4.4 or newer is required (found $BASH_VERSION)" >&2
  exit 1
fi

bindir="$prefix/bin"
share="$prefix/share/my_claude"
mkdir -p "$bindir" "$share/lib" "$share/libexec"

install -m 755 "$here/bin/my_claude" "$bindir/my_claude"
install -m 644 "$here/lib/doctor.sh" "$share/lib/doctor.sh"
install -m 644 "$here/libexec/sync_models.py" "$share/libexec/sync_models.py"
install -m 644 "$here/libexec/dashboard.py" "$share/libexec/dashboard.py"
install -m 644 "$here/pyproject.toml" "$share/pyproject.toml"
install -m 644 "$here/uv.lock" "$share/uv.lock"
echo "Installed my_claude to $bindir/my_claude"

case ":$PATH:" in
  *":$bindir:"*) ;;
  *)
    echo
    echo "$bindir is not on your PATH. Add this line to ~/.bashrc or ~/.zshrc, then open a new shell:"
    echo "  export PATH=\"$bindir:\$PATH\""
    ;;
esac

if [ "$deps" -eq 1 ]; then
  echo
  "$bindir/my_claude" install-deps
fi

echo
echo "Next steps:"
echo "  my_claude login     sign in to GitHub Copilot (one time)"
echo "  my_claude doctor    check the setup"
echo "  my_claude           start Claude Code"
