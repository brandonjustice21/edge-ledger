#!/usr/bin/env bash
# Fetches current odds for each entry in docs/watchlist.json from the OddsJam/OpticOdds
# API and writes docs/odds-snapshot.json. Requires ODDSJAM_API_KEY in the environment.
set -euo pipefail

API_BASE="https://api.opticodds.com/api/v3"
WATCHLIST="docs/watchlist.json"
OUT="docs/odds-snapshot.json"

if [ -z "${ODDSJAM_API_KEY:-}" ]; then
  echo "ODDSJAM_API_KEY is not set — add it as a repository secret." >&2
  exit 1
fi

# sport name (as used in Edge Ledger) -> OpticOdds {sport, league}. Best-effort mapping;
# adjust here if a sport keeps coming back with no matching games.
map_sport() {
  case "$1" in
    NFL) echo "football nfl" ;;
    NCAAF) echo "football ncaaf" ;;
    NBA) echo "basketball nba" ;;
    NCAAB) echo "basketball ncaab" ;;
    MLB) echo "baseball mlb" ;;
    NHL) echo "hockey nhl" ;;
    Soccer) echo "soccer -" ;;
    Tennis) echo "tennis -" ;;
    Golf) echo "golf -" ;;
    "MMA/Boxing") echo "mma -" ;;
    *) echo "- -" ;;
  esac
}

count=$(jq 'length' "$WATCHLIST")
results="[]"

for i in $(seq 0 $((count - 1))); do
  entry=$(jq -c ".[$i]" "$WATCHLIST")
  label=$(echo "$entry" | jq -r '.label')
  sport=$(echo "$entry" | jq -r '.sport')
  team=$(echo "$entry" | jq -r '.team')
  book=$(echo "$entry" | jq -r '.sportsbook // "DraftKings"')

  read -r op_sport op_league <<< "$(map_sport "$sport")"

  fixtures_url="$API_BASE/fixtures/active?page=1"
  [ "$op_sport" != "-" ] && fixtures_url="$fixtures_url&sport=$op_sport"
  [ "$op_league" != "-" ] && fixtures_url="$fixtures_url&league=$op_league"

  echo "Looking up fixtures for \"$label\" ($fixtures_url)..." >&2
  fixtures_resp=$(curl -sS -H "X-Api-Key: $ODDSJAM_API_KEY" "$fixtures_url" || echo '{}')

  fixture=$(echo "$fixtures_resp" | jq -c --arg team "$team" '
    (.data // [])
    | map(select(
        ((.home_team_display // "") | test($team; "i")) or
        ((.away_team_display // "") | test($team; "i"))
      ))
    | .[0] // empty
  ' 2>/dev/null || echo "")

  if [ -z "$fixture" ] || [ "$fixture" = "null" ]; then
    entry_result=$(jq -n --arg label "$label" \
      --arg error "No upcoming game matched \"$team\" for sport \"$sport\". Check spelling, or that watchlist.json's sport matches Edge Ledger's sport names exactly." \
      '{label: $label, error: $error}')
  else
    fid=$(echo "$fixture" | jq -r '.id')
    home=$(echo "$fixture" | jq -r '.home_team_display')
    away=$(echo "$fixture" | jq -r '.away_team_display')
    start=$(echo "$fixture" | jq -r '.start_date')

    echo "Matched fixture $fid ($away @ $home). Fetching odds from $book..." >&2
    odds_resp=$(curl -sS -G -H "X-Api-Key: $ODDSJAM_API_KEY" \
      --data-urlencode "fixture_id=$fid" \
      --data-urlencode "sportsbook=$book" \
      "$API_BASE/fixtures/odds" || echo '{}')

    odds=$(echo "$odds_resp" | jq -c '
      [ (.data // [])[] | (.odds // [])[] | {sportsbook, market, selection, price, points, is_main} ]
    ' 2>/dev/null || echo "[]")
    [ -z "$odds" ] && odds="[]"

    entry_result=$(jq -n --arg label "$label" --arg game "$away @ $home" --arg start "$start" --argjson odds "$odds" \
      '{label: $label, game: $game, start: $start, odds: $odds}')
  fi

  results=$(echo "$results" | jq --argjson r "$entry_result" '. + [$r]')
done

jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson entries "$results" \
  '{generatedAt: $ts, entries: $entries}' > "$OUT"

echo "Wrote $OUT" >&2
cat "$OUT" >&2
