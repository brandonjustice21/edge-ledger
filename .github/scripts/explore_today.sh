#!/usr/bin/env bash
# One-off reconnaissance script (not part of the production pipeline): finds today's
# games across sports and lists the actual market names OddsJam/OpticOdds returns for
# one sample game each, so we can see whether player-prop markets are posted yet.
set -uo pipefail

API_BASE="https://api.opticodds.com/api/v3"

if [ -z "${ODDSJAM_API_KEY:-}" ]; then
  echo "ODDSJAM_API_KEY is not set." >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

today_start=$(date -u +%Y-%m-%dT00:00:00Z)
today_end=$(date -u -d "+1 day" +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -v+1d +%Y-%m-%dT00:00:00Z)
echo "Today's UTC window: $today_start to $today_end"
echo

# label: "opticodds_sport opticodds_league(or - for none)"
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
  url="$API_BASE/fixtures/active?page=1&sport=$sp&start_date_after=$today_start&start_date_before=$today_end"
  [ "$lg" != "-" ] && url="$url&league=$lg"

  curl -sS -H "X-Api-Key: $ODDSJAM_API_KEY" "$url" > "$TMP/fx.json" 2>/dev/null || echo '{}' > "$TMP/fx.json"
  count=$(jq -r '(.data // []) | length' "$TMP/fx.json" 2>/dev/null || echo 0)
  echo "=== $label: $count game(s) today ==="
  if [ "$count" != "0" ]; then
    jq -c '(.data // [])[] | {id, away: .away_team_display, home: .home_team_display, start: .start_date}' "$TMP/fx.json" 2>/dev/null
    fid=$(jq -r '(.data // [])[0].id' "$TMP/fx.json")
    curl -sS -G -H "X-Api-Key: $ODDSJAM_API_KEY" \
      --data-urlencode "fixture_id=$fid" \
      --data-urlencode "sportsbook=DraftKings" \
      "$API_BASE/fixtures/odds" > "$TMP/odds.json" 2>/dev/null || echo '{}' > "$TMP/odds.json"
    odds_count=$(jq -r '[(.data // [])[] | (.odds // [])[]] | length' "$TMP/odds.json" 2>/dev/null || echo 0)
    echo "--- sample game $fid: $odds_count odds lines at DraftKings; distinct markets: ---"
    jq -c '[(.data // [])[] | (.odds // [])[] | .market] | unique' "$TMP/odds.json" 2>/dev/null
  fi
  echo
done
