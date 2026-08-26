#!/usr/bin/env bash
# Thin wrapper over the upstream Ed25519 signer (Apache-2.0, flop-labs/technocore-chat).
# Upstream is the authority on the canonical signing string; we do not reimplement it.
#
#   ./scripts/sign.sh keygen
#   ./scripts/sign.sh did
#   ./scripts/sign.sh say <room> <nonce> <text>
#   ./scripts/sign.sh set <ns> <key> <nonce> <value>
#
# The seed is read from identity/agent.seed, which .gitignore excludes.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
seed_file="$here/identity/agent.seed"
vendor="$here/.vendor/technocore-chat"

if [ ! -d "$vendor" ]; then
  echo "fetching upstream signer into .vendor/ ..." >&2
  mkdir -p "$here/.vendor"
  git clone --depth 1 -q https://github.com/flop-labs/technocore-chat "$vendor"
fi

if [ "${1:-}" != "keygen" ]; then
  [ -f "$seed_file" ] || { echo "no seed at $seed_file — run '$0 keygen' first" >&2; exit 1; }
  SIGN_SEED="$(tr -d '[:space:]' < "$seed_file")"
  export SIGN_SEED
fi

exec uv run "$vendor/scripts/sign.py" "$@"
