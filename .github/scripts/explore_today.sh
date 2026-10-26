#!/usr/bin/env bash
# One-off reconnaissance: lists the real /sportsbooks entries and checks which of our
# "sharp books" (DraftKings, FanDuel, Novig, Kalshi, Pinnacle, Circa) actually exist
# under those names — and separately confirms whether a single-book fixture/odds query
# still works today for the same NFL fixture explore_today.sh verified earlier.
set -uo pipefail

API_BASE="https://api.opticodds.com/api/v3"

if [ -z "${ODDSJAM_API_KEY:-}" ]; then
  echo "ODDSJAM_API_KEY is not set." >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -sS -H "X-Api-Key: $ODDSJAM_API_KEY" "$API_BASE/sportsbooks" > "$TMP/sb.json" 2>/dev/null || echo '{}' > "$TMP/sb.json"
echo "Total sportsbooks returned: $(jq -r '(.data // []) | length' "$TMP/sb.json" 2>/dev/null)"
echo "All names/ids:"
jq -c '[(.data // [])[] | {id, name}]' "$TMP/sb.json" 2>/dev/null
echo

echo "Matches for our sharp-book list:"
for b in "DraftKings" "FanDuel" "Novig" "Kalshi" "Pinnacle" "Circa"; do
  m=$(jq -c --arg b "$b" '[(.data // [])[] | select((.name // "" | test($b; "i")) or (.id // "" | test($b; "i")))]' "$TMP/sb.json" 2>/dev/null)
  echo "  $b -> $m"
done
echo

echo "=== Sanity check: same fixture 20261027271AB6CD (Cowboys@Eagles), ONE book vs SIX books ==="
curl -sS -G -H "X-Api-Key: $ODDSJAM_API_KEY" \
  --data-urlencode "fixture_id=20261027271AB6CD" \
  --data-urlencode "sportsbook=DraftKings" \
  "$API_BASE/fixtures/odds" > "$TMP/one.json" 2>/dev/null || echo '{}' > "$TMP/one.json"
echo "One book (DraftKings) odds count: $(jq -r '[(.data // [])[] | (.odds // [])[]] | length' "$TMP/one.json" 2>/dev/null)"

curl -sS -G -H "X-Api-Key: $ODDSJAM_API_KEY" \
  --data-urlencode "fixture_id=20261027271AB6CD" \
  --data-urlencode "sportsbook=DraftKings" \
  --data-urlencode "sportsbook=FanDuel" \
  --data-urlencode "sportsbook=Novig" \
  --data-urlencode "sportsbook=Kalshi" \
  --data-urlencode "sportsbook=Pinnacle" \
  --data-urlencode "sportsbook=Circa" \
  "$API_BASE/fixtures/odds" > "$TMP/six.json" 2>/dev/null || echo '{}' > "$TMP/six.json"
echo "Six books (all sharp list) odds count: $(jq -r '[(.data // [])[] | (.odds // [])[]] | length' "$TMP/six.json" 2>/dev/null)"
echo "Six-book raw response (first 400 chars, written to file first to avoid pipefail/curl SIGPIPE):"
head -c 400 "$TMP/six.json"
echo
