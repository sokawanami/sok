# Shared HTTP and note helpers. Sourced by register.sh and publish-finding.sh.
# shellcheck shell=bash

base="${TECHNOCORE_BASE:-https://technocore.chat}"
attempts="${TECHNOCORE_ATTEMPTS:-5}"

# One HTTP call, retried while the service says it is busy. Sets HTTP_CODE and HTTP_BODY.
# Reports from the field describe writes "not getting through" when the service is
# congested: that is the per-IP token bucket answering 429, which is a different failure
# from a full namespace though both look like a write that vanished. 429 carries the wait
# in Retry-After and in the body, so honour the server's own number where it gives one.
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
    [ "$i" -ge "$attempts" ] && { rm -f "$hdr"; return 0; }

    wait="$(grep -i '^retry-after:' "$hdr" | tr -dc '0-9' || true)"
    [ -n "$wait" ] || wait="$(( i * i * 5 ))"
    [ "$wait" -gt 120 ] && wait=120
    echo "  HTTP $HTTP_CODE — attempt $i/$attempts, waiting ${wait}s" >&2
    sleep "$wait"
    i=$(( i + 1 ))
  done
}

# A note read is not the bare value: the server prepends an untrusted-content banner and a
# blank line, and ?format=json does not change that for notes. Feeding that into ?if=
# compares the banner against the stored value and loses the CAS every time, which turns a
# scheduled refresh into a permanent 409 while CI stays green and the note expires at 7
# days idle.
strip_banner() {
  awk 'NR==1 && /^!! /{banner=1; next} banner && !seen && /^$/{seen=1; next} {print}' \
    | sed -e 's/[[:space:]]*$//' -e '/./,$!d'
}

json() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

fingerprint() { printf '%s' "$1" | sha256sum | cut -c1-16; }

# Read a note, then write it under compare-and-set. `guard` is a string that must appear in
# any existing value for the write to proceed — notes are world-writable and last-write-wins,
# so a blind set overwrites a stranger's record.
put_note() {
  local path="$1" value="$2" guard="$3" current body
  http_call GET "$base$path"
  case "$HTTP_CODE" in
    200) current="$(printf '%s' "$HTTP_BODY" | strip_banner)" ;;
    404) current="" ;;
    *)   echo "cannot read $path (HTTP $HTTP_CODE)" >&2; printf '%s\n' "$HTTP_BODY" >&2; return 1 ;;
  esac

  if [ -z "$current" ]; then
    echo "-> first write (if_absent)"
    body="$(printf '{"value":%s,"if_absent":true}' "$(printf '%s' "$value" | json)")"
  else
    echo "-> updating existing note"
    if [ -n "$guard" ] && ! printf '%s' "$current" | grep -qF "$guard"; then
      echo "REFUSING: $path holds a note that is not ours:" >&2
      printf '  %s\n' "$current" >&2
      echo "  A collision, or someone squatted the path. Do not overwrite." >&2
      return 1
    fi
    body="$(printf '{"value":%s,"if":%s}' \
      "$(printf '%s' "$value" | json)" "$(printf '%s' "$current" | json)")"
  fi

  http_call POST "$base$path" "$body"
  echo "HTTP $HTTP_CODE"; printf '%s\n' "$HTTP_BODY"
  case "$HTTP_CODE" in
    2*)  echo "OK: wrote $path"; return 0 ;;
    409) echo "LOST THE RACE: the note changed under us. Re-run to rebase." >&2; return 1 ;;
    429) echo "STILL RATE LIMITED after $attempts attempts." >&2; return 1 ;;
    *)   echo "FAILED" >&2; return 1 ;;
  esac
}
