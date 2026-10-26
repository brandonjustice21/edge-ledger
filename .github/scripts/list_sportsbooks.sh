#!/usr/bin/env bash
# One-off: dumps every sportsbook OddsJam/OpticOdds tracks ({id, name}), paginated.
# Temporary diagnostic script — delete once the real roster has been copied into
# docs/index.html's book-recognition list.
set -uo pipefail

API_BASE="https://api.opticodds.com/api/v3"

if [ -z "${ODDSJAM_API_KEY:-}" ]; then
  echo "ODDSJAM_API_KEY is not set." >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

page=1
: > "$TMP/all.jsonl"
while true; do
  curl -sS -H "X-Api-Key: $ODDSJAM_API_KEY" "$API_BASE/sportsbooks?page=$page" > "$TMP/sb.json" 2>/dev/null || echo '{}' > "$TMP/sb.json"
  n=$(jq -r '(.data // []) | length' "$TMP/sb.json" 2>/dev/null || echo 0)
  echo "Page $page: $n sportsbooks" >&2
  jq -c '(.data // [])[] | {id, name}' "$TMP/sb.json" >> "$TMP/all.jsonl" 2>/dev/null || true
  has_more=$(jq -r '.has_more // false' "$TMP/sb.json" 2>/dev/null || echo "false")
  [ "$has_more" != "true" ] && break
  page=$((page + 1))
done

total=$(wc -l < "$TMP/all.jsonl" | tr -d ' ')
echo "=== Total sportsbooks: $total ==="

mkdir -p docs
jq -s 'sort_by(.name)' "$TMP/all.jsonl" > docs/_sportsbooks-dump.json
echo "Wrote docs/_sportsbooks-dump.json ($total entries)"
