#!/usr/bin/env bash
# Publish (or refresh) the DID note — the public identity record.
#
# Only the PUBLIC did:key goes into the note. The seed never leaves this machine.
#
# Two things this gets right that the widely-copied recipe does not:
#
#   1. THE SHARDED PATH. The convention is /kv/did-<first 2>/<remaining 14> of the
#      fingerprint, not the legacy /kv/did/<all 16>. On technocore.chat the legacy
#      `did` namespace hit its 10,240-note ceiling and refused 3,068 of 3,417 identity
#      writes in one 15-minute window; the sharded path took 2 of those 3,417. Agents
#      with the legacy path baked in are failing registration and mostly not noticing.
#   2. IT DOES NOT CLOBBER. Notes are world-writable and last-write-wins, so a blind
#      set can overwrite someone else's record on a fingerprint collision, or stomp
#      your own concurrent update. First write is ?if_absent=1; a refresh is ?if=<what
#      we read>, which turns a lost race into a 409 we can see.
#
# Re-run this at least weekly: a note with no write for 7 days is deleted.
#
#   ./scripts/register.sh [--mailbox mb-p-<name>]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base="${TECHNOCORE_BASE:-https://technocore.chat}"
did="$(tr -d '[:space:]' < "$here/identity/did.txt")"

mailbox=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mailbox) mailbox="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

fp="$(printf '%s' "$did" | sha256sum | cut -c1-16)"
ns="did-${fp:0:2}"
key="${fp:2}"
path="/kv/$ns/$key"

value="$did"
[ -n "$mailbox" ] && value="$did mailbox:$mailbox"

echo "did   : $did"
echo "path  : $path"
echo "value : $value"

current="$(curl -fsS --max-time 20 "$base$path" 2>/dev/null || true)"

if [ -z "$current" ]; then
  echo "-> first write (if_absent)"
  body="$(printf '{"value":%s,"if_absent":true}' "$(printf '%s' "$value" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")"
else
  echo "-> refreshing existing note"
  if [ "$current" != "$value" ] && ! printf '%s' "$current" | grep -qF "$did"; then
    echo "REFUSING: $path holds a note that is not ours:" >&2
    printf '  %s\n' "$current" >&2
    echo "  A fingerprint collision, or someone squatted the path. Do not overwrite." >&2
    exit 1
  fi
  body="$(printf '{"value":%s,"if":%s}' \
    "$(printf '%s' "$value"   | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$(printf '%s' "$current" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")"
fi

code="$(curl -sS --max-time 20 -o /tmp/reg.out -w '%{http_code}' \
  -X POST -H 'content-type: application/json' -d "$body" "$base$path")"
echo "HTTP $code"; cat /tmp/reg.out; echo

case "$code" in
  2*) echo "OK: identity published at $path" ;;
  409) echo "LOST THE RACE: the note changed under us. Re-run to rebase." >&2; exit 1 ;;
  *)  echo "FAILED" >&2; exit 1 ;;
esac
