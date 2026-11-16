#!/usr/bin/env bash
# Smoke tests. Uses a temp HOME and a stub claude; makes no network calls.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT
pass=0; failn=0

ok()   { pass=$((pass + 1)); echo "ok   $1"; }
bad()  { failn=$((failn + 1)); echo "FAIL $1"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

export HOME="$tmp/home"; mkdir -p "$HOME"
unset XDG_CONFIG_HOME MY_CLAUDE_CONFIG_DIR MY_CLAUDE_DEFAULT_AGENT
export FAKE_CLAUDE_LOG="$tmp/argv"
export PATH="$root/tests/fakebin:$HOME/.local/bin:/usr/bin:/bin"

check "install exits 0" "$root/install.sh" >/dev/null
check "install is idempotent" "$root/install.sh" >/dev/null
check "binary installed" test -x "$HOME/.local/bin/my_claude"
check "packs seeded" test -f "$HOME/.config/my_claude/example.md"

mc="$HOME/.local/bin/my_claude"
check "doctor passes with stub" "$mc" doctor >/dev/null
check "list shows packs" bash -c "'$mc' list | grep -q your-docs-mcp-expert"

"$mc" -p "hello world" >/dev/null 2>&1
check "default pack is example" grep -q 'my_claude/example.md' "$FAKE_CLAUDE_LOG"
check "prompt passed" grep -q '^hello world$' "$FAKE_CLAUDE_LOG"

"$mc" -a your-docs-mcp-expert -p hi -- --model opus >/dev/null 2>&1
check "-a selects pack" grep -q 'your-docs-mcp-expert.md' "$FAKE_CLAUDE_LOG"
check "args after -- passed" grep -q '^opus$' "$FAKE_CLAUDE_LOG"

check "missing pack errors" bash -c "! '$mc' -a nope hi 2>/dev/null"
check "-a without value errors" bash -c "! '$mc' -a 2>/dev/null"
check "show without name errors" bash -c "! '$mc' show 2>/dev/null"
check "unknown flag errors" bash -c "! '$mc' --bogus hi 2>/dev/null"

check "new creates pack" "$mc" new mine >/dev/null
check "new refuses overwrite" bash -c "! '$mc' new mine 2>/dev/null"
echo "# keep" > "$HOME/.config/my_claude/example.md"
"$mc" init >/dev/null
check "init does not overwrite" grep -q '^# keep$' "$HOME/.config/my_claude/example.md"

check "stdin used for -p" bash -c "echo piped | '$mc' -p >/dev/null 2>&1 && grep -q '^piped$' '$FAKE_CLAUDE_LOG'"

PATH="/usr/bin:/bin" "$mc" doctor >/dev/null 2>&1
check "doctor fails without claude" test "$?" -ne 0

"$root/uninstall.sh" >/dev/null
check "uninstall removes binary" test ! -e "$mc"
check "uninstall keeps packs" test -f "$HOME/.config/my_claude/mine.md"

echo; echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
