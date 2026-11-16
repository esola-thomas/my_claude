#!/usr/bin/env bash
# Remove the files install.sh created. Your packs in the config directory are left alone.
set -euo pipefail

prefix="${1:-$HOME/.local}"
config="${MY_CLAUDE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/my_claude}"

for p in "$prefix/bin/my_claude" "$prefix/lib/my_claude/doctor.sh" \
         "$prefix/share/my_claude/agents/example.md" \
         "$prefix/share/my_claude/agents/your-docs-mcp-expert.md"; do
  if [ -e "$p" ] || [ -L "$p" ]; then rm "$p"; echo "removed $p"; fi
done
rmdir "$prefix/lib/my_claude" "$prefix/share/my_claude/agents" "$prefix/share/my_claude" 2>/dev/null || true
echo "Left in place (delete by hand if you want): $config"
