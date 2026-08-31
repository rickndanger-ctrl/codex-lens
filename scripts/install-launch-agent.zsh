#!/bin/zsh
set -euo pipefail

repo_root="/Users/richardholguin/Foundry/codex-lens"
agent_source="$repo_root/support/com.codex-lens.gateway.plist"
agent_target="/Users/richardholguin/Library/LaunchAgents/com.codex-lens.gateway.plist"
logs_dir="/Users/richardholguin/Library/Logs/CodexLens"
data_dir="/Users/richardholguin/Library/Application Support/CodexLens"
domain="gui/$(id -u)"

mkdir -p "$logs_dir" "$data_dir" "${agent_target:h}"
chmod 700 "$data_dir"
install -m 600 "$agent_source" "$agent_target"
chmod 700 "$repo_root/scripts/run-gateway.zsh"

launchctl bootout "$domain/com.codex-lens.gateway" 2>/dev/null || true
launchctl bootstrap "$domain" "$agent_target"
launchctl enable "$domain/com.codex-lens.gateway"
launchctl kickstart -k "$domain/com.codex-lens.gateway"

echo "Codex Lens gateway LaunchAgent installed."
