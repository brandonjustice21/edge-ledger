#!/usr/bin/env bash
# One-off reconnaissance script (not part of the production pipeline): for each sport,
# shows the next several upcoming fixtures (no date filter — a previous version used
# start_date_after/start_date_before and got zero results for every single sport
# including soccer, which plays somewhere every day, so that param combo is almost
# certainly wrong rather than there being no games) and lists the real market names
# available for the nearest one, so we can see what's actually posted right now.
set -uo pipefail

API_BASE="https://api.opticodds.com/api/v3"

if [ -z "${ODDSJAM_API_KEY:-}" ]; then
  echo "ODDSJAM_API_KEY is not set." >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
today_date=$(date -u +%Y-%m-%d)
echo "Now (UTC): $now_iso"
echo

SPORTS=(
  "NFL:football:nfl"
  "NCAAF:football:ncaaf"
  "NBA:basketball:nba"
  "NCAAB:basketball:ncaab"
  "MLB:baseball:mlb"
  "NHL:hockey:nhl"
  "Soccer:soccer:-"
)

for row in "${SPORTS[@]}"; do
  IFS=":" read -r label sp lg <<< "$row"
  url="$API_BASE/fixtures/active?page=1&sport=$sp"
  [ "$lg" != "-" ] && url="$url&league=$lg"

  curl -sS -H "X-Api-Key: $ODDSJAM_API_KEY" "$url" > "$TMP/fx.json" 2>/dev/null || echo '{}' > "$TMP/fx.json"
  count=$(jq -r '(.data // []) | length' "$TMP/fx.json" 2>/dev/null || echo 0)
  echo "=== $label: $count fixture(s) on page 1 (no date filter) ==="
  jq -c '[(.data // [])[] | {id, away: .away_team_display, home: .home_team_display, start: .start_date}][0:5]' "$TMP/fx.json" 2>/dev/null

  # Pick whichever fixture (if any) starts today in UTC; otherwise fall back to the
  # first one returned, just to see the market-name conventions for this sport.
  fid=$(jq -r --arg d "$today_date" '
    (.data // []) | map(select((.start_date // "") | startswith($d))) | .[0].id // (.data[0].id // empty)
  ' "$TMP/fx.json" 2>/dev/null)
  is_today=$(jq -r --arg d "$today_date" '
    (.data // []) | map(select((.start_date // "") | startswith($d))) | length > 0
  ' "$TMP/fx.json" 2>/dev/null)

  if [ -n "$fid" ] && [ "$fid" != "null" ]; then
    echo "--- checking markets for fixture $fid (starts today: $is_today) ---"
    curl -sS -G -H "X-Api-Key: $ODDSJAM_API_KEY" \
      --data-urlencode "fixture_id=$fid" \
      --data-urlencode "sportsbook=DraftKings" \
      "$API_BASE/fixtures/odds" > "$TMP/odds.json" 2>/dev/null || echo '{}' > "$TMP/odds.json"
    odds_count=$(jq -r '[(.data // [])[] | (.odds // [])[]] | length' "$TMP/odds.json" 2>/dev/null || echo 0)
    echo "    $odds_count odds lines at DraftKings; distinct markets:"
    jq -c '[(.data // [])[] | (.odds // [])[] | .market] | unique' "$TMP/odds.json" 2>/dev/null
  fi
  echo
done
