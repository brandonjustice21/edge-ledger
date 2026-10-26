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
PLAYER_SEARCH_PAGES=50

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

  # Confirmed against the live API: /players?league=<id>&page=N works (100 real players
  # came back for sport=football) — so this is the right call shape. NBA specifically
  # came back empty across every parameter variant tried (league id, numerical id, name,
  # sport alone), which is a data-coverage gap for that league on OddsJam's/OpticOdds'
  # side, not a bug here. If a league keeps coming back with zero despite a real player
  # name, that's the first thing to suspect — not the request format.
  echo "Searching $op_league players for \"$player\"..." >&2
  pid=""; pname=""; team_id=""; total_seen=0
  for page in $(seq 1 "$PLAYER_SEARCH_PAGES"); do
    curl -sS -H "X-Api-Key: $ODDSJAM_API_KEY" "$API_BASE/players?league=$op_league&page=$page" > "$TMP/players.json" || echo '{}' > "$TMP/players.json"
    page_n=$(jq -r '(.data // []) | length' "$TMP/players.json" 2>/dev/null || echo 0)
    total_seen=$((total_seen + page_n))
    found=$(jq -c --arg name "$player" '
      (.data // []) | map(select(
        (.name // "" | test($name; "i")) or (.last_name // "" | test($name; "i"))
      )) | .[0] // empty
    ' "$TMP/players.json" 2>/dev/null || echo "")
    if [ -n "$found" ] && [ "$found" != "null" ]; then
      pid=$(echo "$found" | jq -r '.id')
      pname=$(echo "$found" | jq -r '.name')
      team_id=$(echo "$found" | jq -r '.team.id // empty')
      break
    fi
    has_more=$(jq -r '.has_more // false' "$TMP/players.json" 2>/dev/null || echo "false")
    [ "$has_more" != "true" ] && break
  done

  if [ -z "$pid" ]; then
    if [ "$total_seen" = "0" ]; then
      jq -n --arg label "$label" --arg error "OddsJam returned zero players for league \"$op_league\" — this looks like a data-coverage gap for that league on their end (not a bad request), not a spelling issue. Confirm with OddsJam/OpticOdds support whether player data is available for this league." \
        '{label: $label, error: $error}' >> "$TMP/entries.jsonl"
    else
      jq -n --arg label "$label" --arg error "No $op_league player matched \"$player\" across $total_seen players checked. Check spelling." \
        '{label: $label, error: $error}' >> "$TMP/entries.jsonl"
    fi
    return
  fi

  if [ -z "$team_id" ]; then
    jq -n --arg label "$label" --arg pname "$pname" --arg error "Matched $pname but the API didn't return a team for them, so their fixture can't be looked up." \
      '{label: $label, error: $error}' >> "$TMP/entries.jsonl"
    return
  fi

  # Confirmed by direct test: /fixtures/odds?player_id=X returns ZERO odds even for a
  # player whose game has 3000+ real odds lines (including dozens of "Player ..."
  # markets) when the SAME fixture is queried by fixture_id instead — so player_id
  # filtering on this endpoint doesn't work as documented. Use team_id to find their
  # fixture (the same proven-working lookup as the team/game path), then filter the
  # full fixture odds by market name AND the player's own name in the selection text.
  echo "Matched player $pid ($pname, team $team_id). Finding their fixture..." >&2
  curl -sS -H "X-Api-Key: $ODDSJAM_API_KEY" "$API_BASE/fixtures/active?team_id=$team_id&page=1" > "$TMP/pfixtures.json" || echo '{}' > "$TMP/pfixtures.json"
  fid=$(jq -r '(.data // [])[0].id // empty' "$TMP/pfixtures.json" 2>/dev/null)

  if [ -z "$fid" ]; then
    jq -n --arg label "$label" --arg pname "$pname" --arg error "Matched $pname but found no upcoming fixture for their team (team_id $team_id)." \
      '{label: $label, error: $error}' >> "$TMP/entries.jsonl"
    return
  fi

  echo "Found fixture $fid. Fetching \"$market\" odds from sharp books..." >&2
  local -a sb_args=()
  while IFS= read -r sb; do
    sb_args+=(--data-urlencode "sportsbook=$sb")
  done < <(echo "$sharp_books" | jq -r '.[]')

  curl -sS -G -H "X-Api-Key: $ODDSJAM_API_KEY" \
    --data-urlencode "fixture_id=$fid" \
    "${sb_args[@]}" \
    "$API_BASE/fixtures/odds" > "$TMP/odds_raw.json" || echo '{}' > "$TMP/odds_raw.json"

  kw_pattern=$(market_keywords "$market")
  # last name only, for matching against the selection text (e.g. "Hurts" in
  # "Jalen Hurts Over 215.5") — the full "pname" often won't appear verbatim
  name_kw=$(echo "$pname" | awk '{print $NF}')

  raw_odds_count=$(jq -r '[(.data // [])[] | (.odds // [])[]] | length' "$TMP/odds_raw.json" 2>/dev/null || echo 0)
  echo "  [debug] raw odds entries for this fixture (any market, these books): $raw_odds_count" >&2

  jq -c --argjson cap "$MAX_ODDS_PER_GAME" --arg kw "$kw_pattern" --arg nm "$name_kw" '
    [ (.data // [])[] | (.odds // [])[]
      | select(.market as $m | ($m // "" | test($kw; "i")))
      | select((.selection // "") + " " + (.name // "") | test($nm; "i"))
      | {sportsbook, market, selection: (if (.selection // "") == "" then (.name // "") else .selection end), price, points}
    ] | sort_by(.sportsbook) | .[0:$cap]
  ' "$TMP/odds_raw.json" > "$TMP/odds.json" 2>/dev/null || echo "[]" > "$TMP/odds.json"

  matched_count=$(jq -r 'length' "$TMP/odds.json" 2>/dev/null || echo 0)

  if [ "$matched_count" = "0" ]; then
    if [ "$raw_odds_count" = "0" ]; then
      jq -n --arg label "$label" --arg pname "$pname" --arg error "Matched $pname's fixture ($fid), but these sharp books have posted no odds for it at all yet — normal well before kickoff. Re-run closer to game time." \
        '{label: $label, error: $error}' >> "$TMP/entries.jsonl"
    else
      echo "  [debug] $raw_odds_count raw odds lines exist but none matched market \"$market\" (pattern: $kw_pattern) + name \"$name_kw\". Distinct markets containing this player's name:" >&2
      jq -c --arg nm "$name_kw" '[(.data // [])[] | (.odds // [])[] | select((.selection // "")+" "+(.name // "") | test($nm; "i")) | .market] | unique' "$TMP/odds_raw.json" >&2 2>/dev/null || true
      jq -n --arg label "$label" --arg pname "$pname" --arg market "$market" --arg error "Matched $pname's fixture ($raw_odds_count odds lines total), but none matched market \"$market\" for this player. Check the Action log and adjust market_keywords() in update_odds.sh." \
        '{label: $label, error: $error}' >> "$TMP/entries.jsonl"
    fi
    return
  fi

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
