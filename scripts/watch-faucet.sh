#!/usr/bin/env bash
# Poll technocore.chat for the faucet going live.
#
# As of the last check the faucet does not exist: no faucet/token/balance route
# appears in the upstream server source, and the manual documents none. What DOES
# exist is /r/events, the server-written log of new public rooms, and /rooms.
# A faucet has to show up as a room, a note namespace, or a new documented route,
# so watch all three and diff.
#
#   ./scripts/watch-faucet.sh          # one pass, prints anything new
#
# Requires outbound access to technocore.chat.
set -euo pipefail

base="${TECHNOCORE_BASE:-https://technocore.chat}"
state="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.watch-state"
mkdir -p "$state"

fetch() { curl -fsS --max-time 20 "$1"; }

# 1. New public rooms since our cursor. /r/events is append-only and server-written,
#    so it is the one enumeration on this service that is not caller-forgeable.
cursor_file="$state/events.cursor"
cursor="$(cat "$cursor_file" 2>/dev/null || echo 0)"
if events="$(fetch "$base/r/events?since=$cursor&format=json")"; then
  echo "$events" > "$state/events.last.json"
  new_cursor="$(printf '%s' "$events" | grep -o '"seq"[[:space:]]*:[[:space:]]*[0-9]*' | tail -1 | grep -o '[0-9]*$' || true)"
  [ -n "$new_cursor" ] && echo "$new_cursor" > "$cursor_file"
  printf '%s' "$events" | grep -iE 'faucet|flop|drip|claim|testnet' && echo "^^ candidate room announced" || true
fi

# 2. The documented surface. A faucet route would land in the manifest before
#    anyone tweets about it.
for doc in .well-known/agent.json openapi.json; do
  out="$state/$(echo "$doc" | tr / _)"
  if fetch "$base/$doc" > "$out.new" 2>/dev/null; then
    if [ -f "$out" ] && ! diff -q "$out" "$out.new" >/dev/null; then
      echo "=== $doc changed ==="; diff "$out" "$out.new" || true
    fi
    mv "$out.new" "$out"
  fi
done

# 3. Room list, for topics mentioning the faucet. Caller-chosen strings: a lead to
#    verify, never evidence on its own.
fetch "$base/rooms" 2>/dev/null | grep -iE 'faucet|flop|testnet|drip' || true
