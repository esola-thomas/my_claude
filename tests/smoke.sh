#!/usr/bin/env bash
# Smoke tests. Temp HOME, stub claude, stub proxy and stub Copilot catalog. No network.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
py="$(command -v "${PYTHON:-python3}")"
stub_pid=""
cleanup() {
  if [ -n "$stub_pid" ]; then kill "$stub_pid" 2>/dev/null || true; fi
  if [ -x "$tmp/prefix/bin/my_claude" ]; then "$tmp/prefix/bin/my_claude" stop-all >/dev/null 2>&1 || true; fi
  rm -r "$tmp"
}
trap cleanup EXIT
pass=0; failn=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }

port=$((20000 + RANDOM % 20000))
cat_port=$((port + 1))
export HOME="$tmp/home"; mkdir -p "$HOME"
export MY_CLAUDE_HOME="$tmp/state" MY_CLAUDE_PORT="$port"
export GITHUB_COPILOT_TOKEN_DIR="$tmp/tok"
export MY_CLAUDE_CATALOG_URL="http://127.0.0.1:$cat_port/models"
export FAKE_CLAUDE_LOG="$tmp/argv"
unset XDG_STATE_HOME MY_CLAUDE_BIN MY_CLAUDE_VENV ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN
export PATH="$root/tests/fakebin:$tmp/prefix/bin:/usr/local/bin:/usr/bin:/bin"

# stub catalog server
"$py" "$root/tests/stub_server.py" "$cat_port" "$root/tests/fixtures/catalog.json" &
stub_pid=$!

# fake venv: python is the real interpreter, litellm is a stub proxy
mkdir -p "$tmp/venv/bin" "$GITHUB_COPILOT_TOKEN_DIR"
ln -s "$py" "$tmp/venv/bin/python"
cat > "$tmp/venv/bin/litellm" <<STUB
#!/usr/bin/env bash
all=("\$@")
while [ \$# -gt 0 ]; do case "\$1" in --port) p="\$2"; shift 2 ;; *) shift ;; esac; done
exec "$py" "$root/tests/stub_server.py" "\$p" "$root/tests/fixtures/catalog.json" "\${all[@]}"
STUB
chmod +x "$tmp/venv/bin/litellm"
export MY_CLAUDE_VENV="$tmp/venv"
mkdir -p "$tmp/stubpy/litellm" && : > "$tmp/stubpy/litellm/__init__.py"
export PYTHONPATH="$tmp/stubpy"

check "install --no-deps exits 0" "$root/install.sh" --prefix "$tmp/prefix" --no-deps
check "install is idempotent" "$root/install.sh" --prefix "$tmp/prefix" --no-deps
mc="$tmp/prefix/bin/my_claude"
check "binary installed" test -x "$mc"
check "version" bash -c "'$mc' version | grep -q my_claude"

check "launch refuses without token" bash -c "! '$mc' -p hi 2>/dev/null"
check "doctor fails without token" bash -c "! '$mc' doctor >/dev/null 2>&1"

echo "fake-test-token" > "$GITHUB_COPILOT_TOKEN_DIR/access-token"; chmod 600 "$GITHUB_COPILOT_TOKEN_DIR/access-token"

"$mc" -p "hello world" >"$tmp/out" 2>"$tmp/err"
check "launch succeeds" grep -q 'ready' "$tmp/err"
check "state dir is 700" test "$(stat -c %a "$tmp/state")" = "700"
check "key file is 600" test "$(stat -c %a "$tmp/state/key")" = "600"
check "key looks generated" grep -qE '^sk-[0-9a-f]{32}$' "$tmp/state/key"
check "no key in config file" bash -c "! grep -q \"\$(cat '$tmp/state/key')\" '$tmp/state/config.yaml'"
check "config has master_key env ref" grep -q 'os.environ/MY_CLAUDE_KEY' "$tmp/state/config.yaml"
check "settings generated" test -s "$tmp/state/settings.json"
check "settings passed to claude" grep -q "ARG:$tmp/state/settings.json" "$FAKE_CLAUDE_LOG"
check "prompt passed" grep -q '^ARG:hello world$' "$FAKE_CLAUDE_LOG"
check "base url exported" grep -q "ENV:ANTHROPIC_BASE_URL=http://127.0.0.1:$port" "$FAKE_CLAUDE_LOG"
check "auth token set" grep -q 'ENV:KEYSET=yes' "$FAKE_CLAUDE_LOG"
check "proxy key not exported to claude" grep -q 'ENV:MY_CLAUDE_KEY=unset' "$FAKE_CLAUDE_LOG"
check "primary model has 1m profile" grep -q 'ENV:ANTHROPIC_MODEL=claude-opus-5.5\[1m\]' "$FAKE_CLAUDE_LOG"
check "launcher output stays off stdout" test ! -s "$tmp/out"

"$mc" -p again >/dev/null 2>"$tmp/err2"
check "second launch reuses proxy" grep -q 'reusing' "$tmp/err2"

"$mc" -p hi -- --model opus >/dev/null 2>&1
check "args after -- reach claude" grep -q '^ARG:--model$' "$FAKE_CLAUDE_LOG"
check "-- itself is passed through" grep -q '^ARG:--$' "$FAKE_CLAUDE_LOG"

echo '{"mcpServers":{}}' > "$tmp/state/mcp.json"
"$mc" -p hi >/dev/null 2>&1
check "mcp.json adds strict config" grep -q '^ARG:--strict-mcp-config$' "$FAKE_CLAUDE_LOG"
"$mc" --all-mcps -p hi >/dev/null 2>&1
check "--all-mcps removes it" bash -c "! grep -q 'strict-mcp-config' '$FAKE_CLAUDE_LOG'"

check "doctor passes" "$mc" doctor
check "status shows proxy" bash -c "'$mc' status | grep -q 'proxy:     running'"

"$mc" stop
check "stop stops the proxy" bash -c "! '$mc' status | grep -q 'proxy:     running'"

"$py" -c "import socket,time;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',$port));s.listen(1);time.sleep(30)" &
foreign=$!
sleep 1
check "foreign listener on port is refused" bash -c "! '$mc' -p hi >/dev/null 2>'$tmp/err3' && grep -q 'not this tool' '$tmp/err3'"
kill "$foreign" 2>/dev/null || true

"$mc" -p hi --output-format json >/dev/null 2>&1 </dev/null
check "no-op sanity" true

"$root/uninstall.sh" "$tmp/prefix" >/dev/null 2>&1
check "uninstall removes binary" test ! -e "$mc"
check "uninstall keeps state" test -f "$tmp/state/key"

echo; echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
