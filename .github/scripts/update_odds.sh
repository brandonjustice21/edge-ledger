#!/usr/bin/env bash
# Fetches current odds for each entry in docs/watchlist.json from the OddsJam/OpticOdds
# API and writes docs/odds-snapshot.json. Requires ODDSJAM_API_KEY in the environment.
#
# All API responses are piped through temp FILES, never shell arguments — a real game's
# odds response can include hundreds of player-prop lines, and passing that much JSON as
# a jq --argjson argument overflows the OS command-line length limit ("Argument list too
# long"). --slurpfile reads from a file instead, so there's no such limit.
#
# Two entry shapes in watchlist.json:
#  - team/game (default, no "type"):  {label, sport, team, sportsbook}
#  - player prop ("type":"player_prop"): {label, sport, player, market, sharpBooks: [...]}
#    "market" is the plain-English stat name (e.g. "Assists", "Passing Yards") as produced
#    by Edge Ledger's prop-shorthand parser; see market_keyword() below for how it's
#    matched against the API's own market-name strings.
set -euo pipefail

API_BASE="https://api.opticodds.com/api/v3"
WATCHLIST="docs/watchlist.json"
OUT="docs/odds-snapshot.json"
MAX_ODDS_PER_GAME=40
PLAYER_SEARCH_PAGES=8

if [ -z "${ODDSJAM_API_KEY:-}" ]; then
  echo "ODDSJAM_API_KEY is not set — add it as a repository secret." >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/entries.jsonl"

# sport name (as used in Edge Ledger) -> OpticOdds {sport, league}. Best-effort mapping;
# adjust here if a sport keeps coming back with no matching games/players.
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

# plain-English stat label (as Edge Ledger's parser writes it into watchlist.json) ->
# lowercase substring(s) to look for in the API's own market name. UNVERIFIED against
# live player-prop data for anything beyond the simple single-stat cases — if a market
# comes back empty, check the Action log for the actual market names OpticOdds used for
# that sport and add them here.
market_keywords() {
  case "$1" in
    "Points + Rebounds + Assists") echo "pra|pts+reb+ast|points + rebounds + assists" ;;
    "Points + Rebounds") echo "pts+reb|points + rebounds" ;;
    "Points + Assists") echo "pts+ast|points + assists" ;;
    "Rebounds + Assists") echo "reb+ast|rebounds + assists" ;;
    "3-Pointers Made") echo "3-point|three" ;;
    "Rebounds") echo "rebound" ;;
    "Assists") echo "assist" ;;
    "Steals") echo "steal" ;;
    "Blocks") echo "block" ;;
    "Turnovers") echo "turnover" ;;
    "Passing Yards") echo "passing yard" ;;
    "Rushing Yards") echo "rushing yard" ;;
    "Receiving Yards") echo "receiving yard" ;;
    "Receptions") echo "reception" ;;
    "Passing Touchdowns") echo "passing touchdown|pass td" ;;
    "Rushing Touchdowns") echo "rushing touchdown|rush td" ;;
    "Touchdowns") echo "touchdown" ;;
    "Strikeouts") echo "strikeout" ;;
    "Home Runs") echo "home run" ;;
    "Total Bases") echo "total base" ;;
    "RBIs") echo "rbi" ;;
    "Hits") echo "hit" ;;
    "Shots on Goal") echo "shots on goal|shot on goal" ;;
    "Saves") echo "save" ;;
    "Goals") echo "goal" ;;
    "Points") echo "point" ;;
    *) echo "$(echo "$1" | tr '[:upper:]' '[:lower:]')" ;;
  esac
}

process_team_entry() {
  local entry="$1" label="$2" sport="$3"
  local team book op_sport op_league fixtures_url fixture_content fid home away start

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
    return
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
  jq -c --argjson cap "$MAX_ODDS_PER_GAME" '
    [ (.data // [])[] | (.odds // [])[]
      | select(.is_main == true)
      | select(.market as $m | ["Moneyline","Point Spread","Spread","Total Points","Total","Game Total"] | index($m))
      | {sportsbook, market, selection: (if (.selection // "") == "" then (.name // "") else .selection end), price, points}
    ] | .[0:$cap]
  ' "$TMP/odds_raw.json" > "$TMP/odds.json" 2>/dev/null || echo "[]" > "$TMP/odds.json"

  jq -n --slurpfile odds "$TMP/odds.json" --arg label "$label" --arg game "$away @ $home" --arg start "$start" \
    '{label: $label, game: $game, start: $start, odds: $odds[0]}' >> "$TMP/entries.jsonl"
}

process_player_prop_entry() {
  local entry="$1" label="$2" sport="$3"
  local player market sharp_books op_sport op_league page pid pname found kw_pattern

  player=$(echo "$entry" | jq -r '.player')
  market=$(echo "$entry" | jq -r '.market')
  sharp_books=$(echo "$entry" | jq -c '.sharpBooks // ["DraftKings","FanDuel","Novig","Kalshi","Pinnacle","Circa"]')
  read -r op_sport op_league <<< "$(map_sport "$sport")"

  if [ "$op_league" = "-" ]; then
    jq -n --arg label "$label" --arg error "Entry's sport \"$sport\" isn't set to a real league — fix \"sport\" in watchlist.json (e.g. NBA, NFL, MLB, NHL)." \
      '{label: $label, error: $error}' >> "$TMP/entries.jsonl"
    return
  fi

  # Round 1 proved "NBA" (uppercase) returns a perfectly valid, empty response
  # ({"data":[],"has_more":false}) — HTTP 200, not an error, just the wrong league code.
  # Revert to lowercase (confirmed working for /fixtures/active with NFL). If this is
  # STILL empty, dump /leagues so the real id shows up in the log instead of guessing again.
  echo "Searching $op_league players for \"$player\"..." >&2
  pid=""; pname=""
  for page in $(seq 1 "$PLAYER_SEARCH_PAGES"); do
    if [ "$page" = "1" ]; then
      http_status=$(curl -sS -o "$TMP/players.json" -w '%{http_code}' -H "X-Api-Key: $ODDSJAM_API_KEY" "$API_BASE/players?league=$op_league&page=$page" || echo "000")
      echo "  [debug] GET /players?league=$op_league&page=1 -> HTTP $http_status" >&2
      echo "  [debug] body (first 500 chars): $(head -c 500 "$TMP/players.json")" >&2
    else
      curl -sS -H "X-Api-Key: $ODDSJAM_API_KEY" "$API_BASE/players?league=$op_league&page=$page" > "$TMP/players.json" || echo '{}' > "$TMP/players.json"
    fi
    echo "  page $page: $(jq -r '(.data // []) | length' "$TMP/players.json" 2>/dev/null || echo '?') players returned, has_more=$(jq -r '.has_more // "?"' "$TMP/players.json" 2>/dev/null)" >&2
    found=$(jq -c --arg name "$player" '
      (.data // []) | map(select(
        (.name // "" | test($name; "i")) or (.last_name // "" | test($name; "i"))
      )) | .[0] // empty
    ' "$TMP/players.json" 2>/dev/null || echo "")
    if [ -n "$found" ] && [ "$found" != "null" ]; then
      pid=$(echo "$found" | jq -r '.id')
      pname=$(echo "$found" | jq -r '.name')
      break
    fi
    has_more=$(jq -r '.has_more // false' "$TMP/players.json" 2>/dev/null || echo "false")
    [ "$has_more" != "true" ] && break
  done

  if [ -z "$pid" ]; then
    # /leagues confirmed "nba" (lowercase) IS the real, valid league id — so the league
    # value itself isn't the problem; something else about how /players wants it called
    # is. Try a few parameter shapes side by side and log how many players each returns,
    # so whichever one actually works is obvious instead of another single blind guess.
    echo "  [debug] still no match with league=$op_league. Probing alternate /players parameter shapes:" >&2
    curl -sS -H "X-Api-Key: $ODDSJAM_API_KEY" "$API_BASE/players?sport=$op_sport&page=1" > "$TMP/probe1.json" 2>/dev/null || echo '{}' > "$TMP/probe1.json"
    echo "  [debug] sport=$op_sport only -> $(jq -r '(.data // []) | length' "$TMP/probe1.json" 2>/dev/null || echo '?') players" >&2
    curl -sS -H "X-Api-Key: $ODDSJAM_API_KEY" "$API_BASE/players?sport=$op_sport&league=$op_league&page=1" > "$TMP/probe2.json" 2>/dev/null || echo '{}' > "$TMP/probe2.json"
    echo "  [debug] sport=$op_sport + league=$op_league -> $(jq -r '(.data // []) | length' "$TMP/probe2.json" 2>/dev/null || echo '?') players" >&2
    curl -sS -H "X-Api-Key: $ODDSJAM_API_KEY" "$API_BASE/players?league=355&page=1" > "$TMP/probe3.json" 2>/dev/null || echo '{}' > "$TMP/probe3.json"
    echo "  [debug] league=355 (nba's numerical_id) -> $(jq -r '(.data // []) | length' "$TMP/probe3.json" 2>/dev/null || echo '?') players" >&2
    curl -sS -H "X-Api-Key: $ODDSJAM_API_KEY" "$API_BASE/players?league=NBA&page=1" > "$TMP/probe4.json" 2>/dev/null || echo '{}' > "$TMP/probe4.json"
    echo "  [debug] league=NBA (name, re-confirming) -> $(jq -r '(.data // []) | length' "$TMP/probe4.json" 2>/dev/null || echo '?') players" >&2
    for f in probe1 probe2 probe3 probe4; do
      n=$(jq -r '(.data // []) | length' "$TMP/$f.json" 2>/dev/null || echo 0)
      if [ "$n" != "0" ] && [ "$n" != "?" ]; then
        echo "  [debug] >>> $f worked! sample: $(jq -c '(.data // [])[0] | {id,name}' "$TMP/$f.json" 2>/dev/null)" >&2
      fi
    done
  fi

  if [ -z "$pid" ]; then
    jq -n --arg label "$label" --arg error "No $op_league player matched \"$player\" in the first $PLAYER_SEARCH_PAGES pages. Check spelling, or that \"sport\" in watchlist.json is this player's real league." \
      '{label: $label, error: $error}' >> "$TMP/entries.jsonl"
    return
  fi

  echo "Matched player $pid ($pname). Fetching \"$market\" odds from sharp books..." >&2
  local -a sb_args=()
  while IFS= read -r sb; do
    sb_args+=(--data-urlencode "sportsbook=$sb")
  done < <(echo "$sharp_books" | jq -r '.[]')

  curl -sS -G -H "X-Api-Key: $ODDSJAM_API_KEY" \
    --data-urlencode "player_id=$pid" \
    "${sb_args[@]}" \
    "$API_BASE/fixtures/odds" > "$TMP/odds_raw.json" || echo '{}' > "$TMP/odds_raw.json"

  kw_pattern=$(market_keywords "$market")

  jq -c --argjson cap "$MAX_ODDS_PER_GAME" --arg kw "$kw_pattern" '
    [ (.data // [])[] | (.odds // [])[]
      | select(.market as $m | ($m // "" | test($kw; "i")))
      | {sportsbook, market, selection: (if (.selection // "") == "" then (.name // "") else .selection end), price, points}
    ] | sort_by(.sportsbook) | .[0:$cap]
  ' "$TMP/odds_raw.json" > "$TMP/odds.json" 2>/dev/null || echo "[]" > "$TMP/odds.json"

  jq -n --slurpfile odds "$TMP/odds.json" --arg label "$label" --arg game "$pname — $market" \
    '{label: $label, game: $game, odds: $odds[0]}' >> "$TMP/entries.jsonl"
}

count=$(jq 'length' "$WATCHLIST")

for i in $(seq 0 $((count - 1))); do
  entry=$(jq -c ".[$i]" "$WATCHLIST")
  label=$(echo "$entry" | jq -r '.label')
  sport=$(echo "$entry" | jq -r '.sport')
  etype=$(echo "$entry" | jq -r '.type // "team"')

  if [ "$etype" = "player_prop" ]; then
    process_player_prop_entry "$entry" "$label" "$sport"
  else
    process_team_entry "$entry" "$label" "$sport"
  fi
done

jq -s --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{generatedAt: $ts, entries: .}' "$TMP/entries.jsonl" > "$OUT"

echo "Wrote $OUT" >&2
wc -c "$OUT" >&2
