# shellcheck shell=bash
# shellcheck disable=SC2154  # SELF, CONFIG_DIR, PACK_*_BYTES come from bin/my_claude
# doctor: check that my_claude and its dependencies are set up. Sourced by bin/my_claude.
# Command output is captured into variables before matching, so pipefail/SIGPIPE cannot kill it.

_fails=0
_warns=0

_pass() { printf 'PASS  %-18s %s\n' "$1" "$2"; }
_warn() { printf 'WARN  %-18s %s\n' "$1" "$2"; _warns=$((_warns + 1)); }
_fail() { printf 'FAIL  %-18s %s\n' "$1" "$2"; _fails=$((_fails + 1)); }
_info() { printf 'INFO  %-18s %s\n' "$1" "$2"; }

run_doctor() {
  local probe=0 arg
  for arg in "$@"; do
    case "$arg" in
      --probe) probe=1 ;;
      -h|--help)
        echo "usage: my_claude doctor [--probe]"
        echo "  --probe  make one small API call to confirm packs reach the model"
        return 0 ;;
      *) echo "my_claude doctor: unknown option '$arg'" >&2; return 2 ;;
    esac
  done

  local out

  if [ "$(uname -s)" = "Linux" ]; then _pass os "Linux"; else _warn os "$(uname -s): only Linux is tested"; fi

  if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }; then
    _pass bash "$BASH_VERSION"
  else
    _fail bash "$BASH_VERSION is older than 4.4"
  fi

  local claude_path="" help_text=""
  if claude_path="$(command -v claude 2>/dev/null)"; then
    if out="$(claude --version 2>&1)"; then
      _pass claude "$out ($claude_path)"
      help_text="$(claude --help 2>&1 || true)"
      case "$help_text" in
        *--append-system-prompt-file*|*--append-system-prompt\[-file\]*) _pass claude-flags "--append-system-prompt-file supported" ;;
        *) _fail claude-flags "--append-system-prompt-file not in 'claude --help'; update Claude Code" ;;
      esac
      case "$help_text" in
        *--name*) : ;;
        *) _warn claude-flags "--name not supported; sessions will be unnamed" ;;
      esac
    else
      _fail claude "'claude --version' failed: ${out:0:200}"
    fi
  else
    _fail claude "not on PATH. Install Claude Code: https://docs.claude.com/en/docs/claude-code/setup"
  fi

  if [ -n "$claude_path" ]; then
    if out="$(timeout 20 claude auth status 2>&1)"; then
      _pass auth "claude auth status ok"
    elif [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${CLAUDE_CODE_USE_BEDROCK:-}" ] || [ -n "${CLAUDE_CODE_USE_VERTEX:-}" ]; then
      _pass auth "API or cloud credentials set in environment"
    else
      _warn auth "not logged in. Run: claude  (then /login)"
    fi
  fi

  local hits=0 d seen="" real seen_real=""
  local oldifs="$IFS"
  IFS=:
  for d in $PATH; do
    if [ -z "$d" ] || [ ! -x "$d/my_claude" ]; then continue; fi
    real="$(readlink -f "$d/my_claude")"
    case " $seen_real " in *" $real "*) continue ;; esac
    seen_real="$seen_real $real"
    hits=$((hits + 1))
    seen="$seen $d/my_claude"
    [ "$real" = "$SELF" ] || _warn path "$d/my_claude is a different file than the one running ($SELF)"
  done
  IFS="$oldifs"
  if [ "$hits" -eq 0 ]; then
    _warn path "my_claude is not on PATH (running from $SELF). Add its directory to PATH or run install.sh"
  elif [ "$hits" -gt 1 ]; then
    _warn path "$hits copies on PATH:$seen (first wins; run 'hash -r' after changes)"
  else
    _pass path "$seen"
  fi

  if [ -d "$CONFIG_DIR" ]; then _pass config-dir "$CONFIG_DIR"; else _warn config-dir "$CONFIG_DIR missing. Run: my_claude init"; fi

  local f n=0 size title name
  for f in "$CONFIG_DIR"/*.md; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    name="$(basename "$f" .md)"
    size="$(wc -c < "$f")"
    title="$(sed -n '1s/^# *//p' "$f")"
    if [ "$size" -eq 0 ]; then _fail "pack:$name" "empty file"; continue; fi
    if [ "$size" -gt "$PACK_MAX_BYTES" ]; then _fail "pack:$name" "$size bytes, over limit $PACK_MAX_BYTES"; continue; fi
    if [ "$size" -gt "$PACK_WARN_BYTES" ]; then _warn "pack:$name" "$size bytes is large"; continue; fi
    if [ -z "$title" ]; then _warn "pack:$name" "first line should be '# Title'"; else _pass "pack:$name" "$title"; fi
  done
  if [ "$n" -eq 0 ]; then _fail packs "no packs in $CONFIG_DIR. Run: my_claude init"; fi

  local def
  def="$(default_pack)"
  if [ -n "$def" ] && [ -f "$CONFIG_DIR/$def.md" ]; then
    _pass default-pack "$def"
  elif [ "$n" -gt 0 ]; then
    _fail default-pack "'$def' does not exist; set MY_CLAUDE_DEFAULT_AGENT to a listed pack"
  fi

  if [ -f "$CONFIG_DIR/your-docs-mcp-expert.md" ] && ! command -v your-docs-mcp >/dev/null 2>&1; then
    _info optional "your-docs-mcp-expert pack is installed but 'your-docs-mcp' is not: pip install your-docs-mcp"
  fi

  for n in git gh; do
    if command -v "$n" >/dev/null 2>&1; then _info optional "$n found"; else _info optional "$n not found (not required)"; fi
  done

  if [ "$probe" -eq 1 ]; then
    if [ -z "$claude_path" ]; then
      _fail probe "skipped, claude missing"
    else
      local tmp
      tmp="$(mktemp)"
      echo "The secret canary word is PINEAPPLE-42." > "$tmp"
      if out="$(timeout 90 claude -p --append-system-prompt-file "$tmp" "What is the secret canary word? Reply with only the word." 2>&1)"; then
        case "$out" in
          *PINEAPPLE-42*) _pass probe "pack text reached the model" ;;
          *) _fail probe "model did not see the pack text" ;;
        esac
      else
        _fail probe "claude -p failed: ${out:0:200}"
      fi
      rm "$tmp"
    fi
  fi

  echo
  echo "doctor: $_fails failure(s), $_warns warning(s)"
  [ "$_fails" -eq 0 ]
}
