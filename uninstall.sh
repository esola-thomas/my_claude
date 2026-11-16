#!/usr/bin/env bash
# Remove the files install.sh created. State (key, config, venv) is left until you delete it.
set -euo pipefail

prefix="${1:-$HOME/.local}"
state="${MY_CLAUDE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/my_claude}"
share="$prefix/share/my_claude"

if [ -x "$prefix/bin/my_claude" ]; then "$prefix/bin/my_claude" stop-all || true; fi

for p in "$prefix/bin/my_claude" "$share/lib/doctor.sh" "$share/libexec/sync_models.py" \
         "$share/libexec/dashboard.py" "$share/pyproject.toml" "$share/uv.lock"; do
  if [ -e "$p" ] || [ -L "$p" ]; then rm "$p"; echo "removed $p"; fi
done
rmdir "$share/lib" "$share/libexec" "$share" 2>/dev/null || true
echo "Left in place (delete by hand if you want): $state"
echo "Copilot login token (shared with LiteLLM): ${GITHUB_COPILOT_TOKEN_DIR:-$HOME/.config/litellm/github_copilot}"
