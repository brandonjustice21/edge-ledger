#!/usr/bin/env bash
# One-off reconnaissance script (not part of the production pipeline): for each sport,
# shows the next several upcoming fixtures and lists the real market names available
# for the nearest one, so we can see what's actually posted right now.
#
# Two bugs fixed from the previous version:
#  - the "pick a fixture" jq filter lost its reference to .data after piping through
#    map(), so the fallback branch silently evaluated to null/empty for every sport and
#    the market check never ran at all.
#  - US evening games (NFL Monday night, MLB World Series) often fall on the NEXT
#    calendar day in UTC, so a strict "starts today" UTC-date-string match misses games
#    that are clearly "tonight" locally. Widened to a 36-hour window instead.
set -uo pipefail

API_BASE="https://api.opticodds.com/api/v3"

if [ -z "${ODDSJAM_API_KEY:-}" ]; then
  echo "ODDSJAM_API_KEY is not set." >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
window_end=$(date -u -d "+36 hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+36H +%Y-%m-%dT%H:%M:%SZ)
echo "Now (UTC): $now_iso — treating anything before $window_end as 'today/tonight'"
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
  echo "=== $label: $count fixture(s) on page 1 ==="
  jq -c '[(.data // [])[] | {id, away: .away_team_display, home: .home_team_display, start: .start_date}][0:5]' "$TMP/fx.json" 2>/dev/null

  if [ "$count" = "0" ]; then
    echo
    continue
  fi

  # Fixed: bind .data to $all BEFORE piping into map(), so both branches of the //
  # fallback can still see it (piping through map() replaces `.` with the filtered
  # array, which has no .data key of its own — that was the bug).
  fid=$(jq -r --arg now "$now_iso" --arg until "$window_end" '
    (.data // []) as $all
    | (($all | map(select(.start_date >= $now and .start_date <= $until)) | .[0].id))
      // ($all[0].id) // empty
  ' "$TMP/fx.json" 2>/dev/null)
  is_tonight=$(jq -r --arg now "$now_iso" --arg until "$window_end" '
    (.data // []) | map(select(.start_date >= $now and .start_date <= $until)) | length > 0
  ' "$TMP/fx.json" 2>/dev/null)

  if [ -n "$fid" ] && [ "$fid" != "null" ]; then
    echo "--- checking markets for fixture $fid (today/tonight: $is_tonight) ---"
    curl -sS -G -H "X-Api-Key: $ODDSJAM_API_KEY" \
      --data-urlencode "fixture_id=$fid" \
      --data-urlencode "sportsbook=DraftKings" \
      "$API_BASE/fixtures/odds" > "$TMP/odds.json" 2>/dev/null || echo '{}' > "$TMP/odds.json"
    odds_count=$(jq -r '[(.data // [])[] | (.odds // [])[]] | length' "$TMP/odds.json" 2>/dev/null || echo 0)
    echo "    $odds_count odds lines at DraftKings; distinct markets:"
    jq -c '[(.data // [])[] | (.odds // [])[] | .market] | unique' "$TMP/odds.json" 2>/dev/null
  else
    echo "--- no fixture id resolved, skipping market check ---"
  fi
  echo
done
