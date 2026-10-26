#!/usr/bin/env bash
# Fetches current odds for each entry in docs/watchlist.json from the OddsJam/OpticOdds
# API and writes docs/odds-snapshot.json. Requires ODDSJAM_API_KEY in the environment.
#
# All API responses are piped through temp FILES, never shell arguments — a real game's
# odds response can include hundreds of player-prop lines, and passing that much JSON as
# a jq --argjson argument overflows the OS command-line length limit ("Argument list too
# long"). --slurpfile reads from a file instead, so there's no such limit.
set -euo pipefail

API_BASE="https://api.opticodds.com/api/v3"
WATCHLIST="docs/watchlist.json"
OUT="docs/odds-snapshot.json"
MAX_ODDS_PER_GAME=40

if [ -z "${ODDSJAM_API_KEY:-}" ]; then
  echo "ODDSJAM_API_KEY is not set — add it as a repository secret." >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/entries.jsonl"

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
  curl -sS -H "X-Api-Key: $ODDSJAM_API_KEY" "$fixtures_url" > "$TMP/fixtures.json" || echo '{}' > "$TMP/fixtures.json"

  jq -c --arg team "$team" '
    (.data // [])
    | map(select(
        ((.home_team_display // "") | test($team; "i")) or
        ((.away_team_display // "") | test($team; "i"))
      ))
    | .[0] // empty
  ' "$TMP/fixtures.json" > "$TMP/fixture.json" 2>/dev/null || echo "" > "$TMP/fixture.json"

  fixture_content=$(cat "$TMP/fixture.json")

  if [ -z "$fixture_content" ] || [ "$fixture_content" = "null" ]; then
    jq -n --arg label "$label" \
      --arg error "No upcoming game matched \"$team\" for sport \"$sport\". Check spelling, or that watchlist.json's sport matches Edge Ledger's sport names exactly." \
      '{label: $label, error: $error}' >> "$TMP/entries.jsonl"
    continue
  fi

  fid=$(jq -r '.id' "$TMP/fixture.json")
  home=$(jq -r '.home_team_display' "$TMP/fixture.json")
  away=$(jq -r '.away_team_display' "$TMP/fixture.json")
  start=$(jq -r '.start_date' "$TMP/fixture.json")

  echo "Matched fixture $fid ($away @ $home). Fetching odds from $book..." >&2
  curl -sS -G -H "X-Api-Key: $ODDSJAM_API_KEY" \
    --data-urlencode "fixture_id=$fid" \
    --data-urlencode "sportsbook=$book" \
    "$API_BASE/fixtures/odds" > "$TMP/odds_raw.json" || echo '{}' > "$TMP/odds_raw.json"

  # Keep only the core full-game lines, capped. Two filters, both needed:
  #  - market name, because "is_main" alone marks the primary line *within whatever
  #    market it's on* (it's just as true for "Correct Score" or "1st Half Correct
  #    Score" as for "Point Spread") — without this, exotic/period props get in.
  #  - is_main, because a market like "Point Spread" or "Total Points" also lists every
  #    alternate line (every point value a book offers) — without this, dozens of
  #    alternate spreads/totals get in instead of just the real closing line.
  # A game can otherwise return hundreds of prop/alternate-line rows, which is both the
  # size bug above and a useless wall of text in the "Look up odds" picker.
  jq -c --argjson cap "$MAX_ODDS_PER_GAME" '
    [ (.data // [])[] | (.odds // [])[]
      | select(.is_main == true)
      | select(.market as $m | ["Moneyline","Point Spread","Spread","Total Points","Total","Game Total"] | index($m))
      | {sportsbook, market, selection: (if (.selection // "") == "" then (.name // "") else .selection end), price, points}
    ] | .[0:$cap]
  ' "$TMP/odds_raw.json" > "$TMP/odds.json" 2>/dev/null || echo "[]" > "$TMP/odds.json"

  jq -n --slurpfile odds "$TMP/odds.json" --arg label "$label" --arg game "$away @ $home" --arg start "$start" \
    '{label: $label, game: $game, start: $start, odds: $odds[0]}' >> "$TMP/entries.jsonl"
done

jq -s --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{generatedAt: $ts, entries: .}' "$TMP/entries.jsonl" > "$OUT"

echo "Wrote $OUT" >&2
wc -c "$OUT" >&2
