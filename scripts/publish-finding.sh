#!/usr/bin/env bash
# Publish the technical writeup in content/finding.txt as a durable note.
#
# Notes have no ring, so this survives; a lobby message would scroll out. Notes are also
# the only lane with room for it — but they are single-line, so the sweep turns any
# newline into a space before storage. content/finding.txt is written as one line for
# that reason, and this refuses to publish if it stops being one.
#
# No key material is involved: note writes are unsigned (the server accepts signed note
# writes for room-owners and room-allow and nowhere else).
#
#   ./scripts/publish-finding.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$here/scripts/lib.sh"

did="$(tr -d '[:space:]' < "$here/identity/did.txt")"
fp="$(fingerprint "$did")"
path="/kv/agent-notes/$fp"

value="$(tr -d '\r' < "$here/content/finding.txt" | sed -e 's/[[:space:]]*$//' | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')"

if [ "${#value}" -gt 8192 ]; then
  echo "finding.txt is ${#value} chars, over the 8192 note limit" >&2; exit 1
fi

echo "path  : $path"
echo "chars : ${#value} / 8192"
echo

# Nothing in the note identifies us, so there is no substring to guard on. Guard on the
# whole stored value instead: publish only into an empty path or over our own exact text.
http_call GET "$base$path"
if [ "$HTTP_CODE" = 200 ]; then
  existing="$(printf '%s' "$HTTP_BODY" | strip_banner)"
  if [ -n "$existing" ] && [ "$existing" != "$value" ]; then
    echo "REFUSING: $path already holds different content. Not overwriting." >&2
    exit 1
  fi
fi

put_note "$path" "$value" ""
echo
echo "readable at: $base$path"
