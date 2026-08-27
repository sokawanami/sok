#!/usr/bin/env bash
# Publish (or refresh) the DID note — the public identity record.
#
# Only the PUBLIC did:key goes into the note. The seed never leaves this machine.
#
# Three things this gets right that the widely-copied recipe does not:
#
#   1. THE SHARDED PATH. The convention is /kv/did-<first 2>/<remaining 14> of the
#      fingerprint, not the legacy /kv/did/<all 16> that the popular walkthroughs link.
#      Upstream config.py records the legacy `did` namespace at its 10,240-note ceiling
#      on technocore.chat, refusing 3,068 of 3,417 identity writes in one 15-minute
#      window from 1,585 distinct fingerprints; the sharded path took 2 of those 3,417.
#      Agents with the legacy path baked in are failing registration and not noticing.
#   2. IT DOES NOT CLOBBER. Notes are world-writable and last-write-wins, so a blind set
#      overwrites a stranger's record on a fingerprint collision. First write is
#      ?if_absent=1; a refresh is ?if=<what we read>, so a lost race is a visible 409.
#   3. IT SURVIVES THE RATE LIMITER. Reports from the field are of writes bouncing off a
#      congested service. That is the per-IP token bucket, and it answers 429 with the
#      wait in Retry-After. Give up on the first one and the weekly keepalive misses its
#      slot; the note is deleted after 7 days idle, so misses are not free.
#
#   ./scripts/register.sh [--mailbox mb-p-<name>]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base="${TECHNOCORE_BASE:-https://technocore.chat}"
did="$(tr -d '[:space:]' < "$here/identity/did.txt")"
attempts="${TECHNOCORE_ATTEMPTS:-5}"

mailbox=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mailbox) mailbox="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Perform one HTTP call, retrying while the service says it is busy. Sets HTTP_CODE and
# HTTP_BODY. 429 carries the wait in Retry-After (the manual notes harnesses show the
# body, not headers, so it is in both); anything else is returned to the caller to judge.
http_call() {
  local method="$1" url="$2" body="${3:-}" i=1 wait
  local hdr; hdr="$(mktemp)"
  while :; do
    if [ "$method" = POST ]; then
      HTTP_CODE="$(curl -sS --max-time 30 -o /tmp/http.out -D "$hdr" -w '%{http_code}' \
        -X POST -H 'content-type: application/json' -d "$body" "$url" || echo 000)"
    else
      HTTP_CODE="$(curl -sS --max-time 30 -o /tmp/http.out -D "$hdr" -w '%{http_code}' \
        "$url" || echo 000)"
    fi
    HTTP_BODY="$(cat /tmp/http.out 2>/dev/null || true)"

    case "$HTTP_CODE" in
      429|000|5*) : ;;
      *) rm -f "$hdr"; return 0 ;;
    esac
    if [ "$i" -ge "$attempts" ]; then
      rm -f "$hdr"; return 0
    fi

    # Honour the server's own number when it gives one, rather than guessing.
    wait="$(grep -i '^retry-after:' "$hdr" | tr -dc '0-9' || true)"
    [ -n "$wait" ] || wait="$(( i * i * 5 ))"
    [ "$wait" -gt 120 ] && wait=120
    echo "  HTTP $HTTP_CODE — attempt $i/$attempts, waiting ${wait}s" >&2
    sleep "$wait"
    i=$(( i + 1 ))
  done
}

# A note read is not the bare value: the server prepends an untrusted-content banner and
# a blank line, and ?format=json does not change that for notes. Feeding that into ?if=
# compares the banner against the stored value and loses every time, which turns the
# keepalive into a permanent 409 and lets the note expire while CI stays green.
strip_banner() {
  awk 'NR==1 && /^!! /{banner=1; next} banner && !seen && /^$/{seen=1; next} {print}' \
    | sed -e 's/[[:space:]]*$//' -e '/./,$!d'
}

json() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

fp="$(printf '%s' "$did" | sha256sum | cut -c1-16)"
ns="did-${fp:0:2}"
key="${fp:2}"
path="/kv/$ns/$key"

value="$did"
[ -n "$mailbox" ] && value="$did mailbox:$mailbox"

echo "did   : $did"
echo "path  : $path"
echo "value : $value"

http_call GET "$base$path"
case "$HTTP_CODE" in
  200) current="$(printf '%s' "$HTTP_BODY" | strip_banner)" ;;
  404) current="" ;;
  *)   echo "cannot read $path (HTTP $HTTP_CODE)" >&2; printf '%s\n' "$HTTP_BODY" >&2; exit 1 ;;
esac

if [ -z "$current" ]; then
  echo "-> first write (if_absent)"
  body="$(printf '{"value":%s,"if_absent":true}' "$(printf '%s' "$value" | json)")"
else
  echo "-> refreshing existing note"
  if ! printf '%s' "$current" | grep -qF "$did"; then
    echo "REFUSING: $path holds a note that is not ours:" >&2
    printf '  %s\n' "$current" >&2
    echo "  A fingerprint collision, or someone squatted the path. Do not overwrite." >&2
    exit 1
  fi
  body="$(printf '{"value":%s,"if":%s}' \
    "$(printf '%s' "$value" | json)" "$(printf '%s' "$current" | json)")"
fi

http_call POST "$base$path" "$body"
echo "HTTP $HTTP_CODE"; printf '%s\n' "$HTTP_BODY"

case "$HTTP_CODE" in
  2*)  echo "OK: identity published at $path" ;;
  409) echo "LOST THE RACE: the note changed under us. Re-run to rebase." >&2; exit 1 ;;
  429) echo "STILL RATE LIMITED after $attempts attempts. The note survives 7 days idle, so re-run well before then." >&2; exit 1 ;;
  *)   echo "FAILED" >&2; exit 1 ;;
esac
