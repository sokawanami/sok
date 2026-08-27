#!/usr/bin/env bash
# Publish (or refresh) the DID note — the public identity record.
#
# Only the PUBLIC did:key goes into the note. The seed never leaves this machine.
#
# The path is derived, not chosen: /kv/did-<first 2>/<remaining 14> of the fingerprint,
# NOT the legacy /kv/did/<all 16> the popular walkthroughs link. CHANGELOG 0.8.0 records
# the legacy namespace reaching its 5120-note cap; see content/finding.txt.
#
# Re-run at least weekly: a note with no write for 7 days is deleted.
#
#   ./scripts/register.sh [--mailbox mb-p-<name>]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
. "$here/scripts/lib.sh"

did="$(tr -d '[:space:]' < "$here/identity/did.txt")"

mailbox=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mailbox) mailbox="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

fp="$(fingerprint "$did")"
path="/kv/did-${fp:0:2}/${fp:2}"

value="$did"
[ -n "$mailbox" ] && value="$did mailbox:$mailbox"

echo "did   : $did"
echo "path  : $path"
echo "value : $value"

put_note "$path" "$value" "$did"
