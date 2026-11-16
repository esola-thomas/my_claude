# shellcheck shell=bash
# shellcheck disable=SC2154  # variables come from bin/my_claude
# doctor: check that my_claude and its dependencies are set up. Sourced by bin/my_claude.
# Command output is captured into variables before matching, so pipefail/SIGPIPE cannot kill it.

_fails=0
_warns=0

_pass() { printf 'PASS  %-16s %s\n' "$1" "$2"; }
_warn() { printf 'WARN  %-16s %s\n' "$1" "$2"; _warns=$((_warns + 1)); }
_fail() { printf 'FAIL  %-16s %s\n' "$1" "$2"; _fails=$((_fails + 1)); }
_info() { printf 'INFO  %-16s %s\n' "$1" "$2"; }

_mode() { stat -c %a "$1" 2>/dev/null || echo "?"; }

run_doctor() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -h|--help) echo "usage: my_claude doctor"; return 0 ;;
      *) echo "my_claude doctor: unknown option '$arg'" >&2; return 2 ;;
    esac
  done

  local out rc m

  if [ "$(uname -s)" = "Linux" ]; then _pass os "Linux"; else _warn os "$(uname -s): only Linux is tested"; fi
  _pass bash "$BASH_VERSION"

  if command -v curl >/dev/null 2>&1; then _pass curl "found"; else _fail curl "not found"; fi
  if command -v flock >/dev/null 2>&1; then _pass flock "found"; else _fail flock "not found (util-linux)"; fi
  if command -v ss >/dev/null 2>&1; then _pass ss "found"; else _warn ss "not found; port checks fall back to /dev/tcp"; fi

  local claude_path="${MY_CLAUDE_BIN:-}"
  if [ -z "$claude_path" ]; then claude_path="$(command -v claude || true)"; fi
  if [ -n "$claude_path" ] && [ -x "$claude_path" ]; then
    if out="$("$claude_path" --version 2>&1)"; then
      _pass claude "$out ($claude_path)"
      out="$("$claude_path" --help 2>&1 || true)"
      case "$out" in *--settings*) _pass claude-flags "--settings supported" ;; *) _fail claude-flags "--settings not in 'claude --help'; update Claude Code" ;; esac
    else
      _fail claude "'$claude_path --version' failed"
    fi
  else
    _fail claude "not on PATH. Install Claude Code: https://docs.claude.com/en/docs/claude-code/setup"
  fi

  if command -v uv >/dev/null 2>&1; then _pass uv "$(uv --version 2>&1)"; else _fail uv "not found. Install: https://docs.astral.sh/uv/getting-started/installation/"; fi

  if [ -x "$VENV/bin/python" ] && [ -x "$VENV/bin/litellm" ]; then
    if out="$("$VENV/bin/python" -c 'import litellm
try:
    import importlib.metadata as m
    print(m.version("litellm"))
except Exception:
    print("unknown")' 2>&1)"; then
      _pass litellm "version $out in $VENV"
    else
      _fail litellm "import failed: ${out:0:200}. Run: my_claude install-deps"
    fi
  else
    _fail litellm "environment missing at $VENV. Run: my_claude install-deps"
  fi

  if [ -d "$STATE" ]; then
    m="$(_mode "$STATE")"
    if [ "$m" = "700" ]; then _pass state-dir "$STATE (700)"; else _warn state-dir "$STATE has mode $m, expected 700"; fi
    if [ -s "$KEY_FILE" ]; then
      m="$(_mode "$KEY_FILE")"
      if [ "$m" = "600" ]; then _pass key "present (600)"; else _warn key "mode $m, expected 600"; fi
    else
      _info key "not generated yet (created on first launch)"
    fi
  else
    _info state-dir "$STATE does not exist yet (created on first launch)"
  fi

  if [ -s "$TOKEN_FILE" ]; then
    m="$(_mode "$TOKEN_FILE")"
    if [ "$m" = "600" ]; then _pass copilot-token "present (600)"; else _warn copilot-token "mode $m, expected 600"; fi
  else
    _fail copilot-token "missing at $TOKEN_FILE. Run: my_claude login"
  fi

  if [ -s "$TOKEN_FILE" ] && [ -x "$VENV/bin/python" ]; then
    local tmpdir
    tmpdir="$(mktemp -d)"
    if out="$(GITHUB_COPILOT_TOKEN_DIR="$TOKEN_DIR" timeout 60 "$VENV/bin/python" "$SHARE/libexec/sync_models.py" \
        --config "$tmpdir/c.yaml" --settings-out "$tmpdir/s.json" --env-file "$tmpdir/e.env" --check 2>&1)"; then
      _pass copilot-models "${out:0:160}"
    else
      case "$out" in
        *401*) _fail copilot-models "HTTP 401. Run: my_claude login --force" ;;
        *403*) _fail copilot-models "HTTP 403. No Copilot seat, or your organization blocks it" ;;
        *"No enabled"*) _fail copilot-models "$out. Enable Claude models in your Copilot settings" ;;
        *) _fail copilot-models "${out:0:200}" ;;
      esac
    fi
    rm -r "$tmpdir"
  fi

  if [ -f "$KEY_FILE" ]; then
    # shellcheck disable=SC2034  # read by proxy_healthy in bin/my_claude
    KEY="$(cat "$KEY_FILE")"
    if port_in_use "$PORT"; then
      if proxy_owned; then
        if proxy_healthy; then _pass proxy "ours, healthy on :$PORT"; else _warn proxy "ours but unhealthy on :$PORT. Launch will restart it"; fi
      else
        _fail proxy "port $PORT is in use by something else. Set MY_CLAUDE_PORT"
      fi
    else
      _info proxy "not running (started on launch)"
    fi
  fi

  if [ -f "$HOME/.claude/settings.json" ]; then
    out="$(grep -cE '"(modelAliases|modelPicker|availableModels)"' "$HOME/.claude/settings.json" || true)"
    if [ "${out:-0}" -gt 0 ]; then _warn user-settings "$HOME/.claude/settings.json has model keys that may override the generated ones"; fi
  fi

  case "${HTTPS_PROXY:-}${https_proxy:-}${HTTP_PROXY:-}${http_proxy:-}" in
    "") : ;;
    *) case "${NO_PROXY:-}${no_proxy:-}" in *127.0.0.1*|*localhost*) _pass http-proxy "proxy set, loopback excluded" ;; *) _warn http-proxy "proxy variables set without NO_PROXY=127.0.0.1 (the launcher adds it for claude)" ;; esac ;;
  esac

  local hits=0 d real seen="" seen_real=""
  local oldifs="$IFS"
  IFS=:
  for d in $PATH; do
    if [ -z "$d" ] || [ ! -x "$d/my_claude" ]; then continue; fi
    real="$(readlink -f "$d/my_claude")"
    case " $seen_real " in *" $real "*) continue ;; esac
    seen_real="$seen_real $real"
    hits=$((hits + 1))
    seen="$seen $d/my_claude"
  done
  IFS="$oldifs"
  if [ "$hits" -eq 0 ]; then _info path "my_claude is not on PATH (running from $SELF)"
  elif [ "$hits" -gt 1 ]; then _warn path "$hits different copies on PATH:$seen (first wins; run 'hash -r')"
  else _pass path "$seen"; fi
  rc=0
  if [ -n "$(type -t my_claude 2>/dev/null || true)" ]; then rc=1; fi
  if [ "$rc" -eq 1 ]; then _warn shell-func "a shell function or alias named my_claude exists in this shell"; fi

  echo
  echo "doctor: $_fails failure(s), $_warns warning(s)"
  [ "$_fails" -eq 0 ]
}
