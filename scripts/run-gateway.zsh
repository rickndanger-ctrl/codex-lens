#!/bin/zsh
set -euo pipefail

repo_root="/Users/richardholguin/Foundry/codex-lens"
security_bin="/usr/bin/security"

export OPENAI_API_KEY="$($security_bin find-generic-password -a codex-lens -s com.codex-lens.gateway.openai-api-key -w)"
export CODEX_LENS_GATEWAY_TOKEN="$($security_bin find-generic-password -a codex-lens -s com.codex-lens.gateway.token -w)"
export CODEX_LENS_HOST="127.0.0.1"
export CODEX_LENS_PORT="8787"
export CODEX_LENS_DB_PATH="/Users/richardholguin/Library/Application Support/CodexLens/gateway.sqlite3"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

cd "$repo_root"
exec /opt/homebrew/opt/node@26/bin/node dist/packages/gateway/src/index.js
