#!/usr/bin/env bash
# Tracks every bet in docs/bets.json against the OddsJam/OpticOdds API. Each bet carries
# its own lifecycle:
#   wageredOdds   - the price the user actually got; set once by hand, never touched here
#   openingOdds   - the first price THIS tracker observes after the bet starts tracking;
#                   set once, on the first successful fetch, and never overwritten again
#   liveOdds      - the most recent fetch; overwritten every run (this workflow runs every
#                   10 minutes) while the bet is still upcoming
#   closingOdds   - locked once the fixture's start time has passed: whatever liveOdds
#                   held at that point, frozen. No further fetches happen after that.
# The user sets the bet's outcome (win/loss/push) themselves in the app; this script
# never touches outcome.
#
# All API responses are piped through temp FILES, never shell arguments — a real game's
# odds response can include hundreds of player-prop lines, and passing that much JSON as
# a jq --argjson argument overflows the OS command-line length limit ("Argument list too
# long"). --slurpfile reads from a file instead, so there's no such limit.
#
# Two bet shapes in bets.json:
#  - team/game ("type":"team" or omitted): {id, label, sport, team, placedBook}
#  - player prop ("type":"player_prop"): {id, label, sport, player, market, sharpBooks: [...]}
#    "market" is the plain-English stat name (e.g. "Assists", "Passing Yards") as produced
#    by Edge Ledger's prop-shorthand parser; see market_keywords() below for how it's
#    matched against the API's own market-name strings.
set -euo pipefail

API_BASE="https://api.opticodds.com/api/v3"
BETS="docs/bets.json"
MAX_ODDS_PER_GAME=40
PLAYER_SEARCH_PAGES=50
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_EPOCH="$(date -u +%s)"

if [ -z "${ODDSJAM_API_KEY:-}" ]; then
  echo "ODDSJAM_API_KEY is not set — add it as a repository secret." >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/bets_out.jsonl"

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

# plain-English stat label (as Edge Ledger's parser writes it into bets.json) -> lowercase
# substring(s) to look for in the API's own market name. If a market comes back empty,
# check the Action log for the actual market names OpticOdds used for that sport and add
# them here.
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

# Resolves a team bet's fixture. Prints "<fixture_id>\t<start_date>" on success, nothing
# on failure.
resolve_team_fixture() {
  local sport="$1" team="$2"
  local op_sport op_league fixtures_url
  read -r op_sport op_league <<< "$(map_sport "$sport")"
  fixtures_url="$API_BASE/fixtures/active?page=1"
  [ "$op_sport" != "-" ] && fixtures_url="$fixtures_url&sport=$op_sport"
  [ "$op_league" != "-" ] && fixtures_url="$fixtures_url&league=$op_league"
  curl -sS -H "X-Api-Key: $ODDSJAM_API_KEY" "$fixtures_url" > "$TMP/fixtures.json" || echo '{}' > "$TMP/fixtures.json"
  jq -r --arg team "$team" '
    (.data // []) | map(select(
      ((.home_team_display // "") | test($team; "i")) or
      ((.away_team_display // "") | test($team; "i"))
    )) | .[0] | select(.!=null) | [.id, .start_date] | @tsv
  ' "$TMP/fixtures.json" 2>/dev/null || true
}

# Resolves a player-prop bet's fixture via their team_id (player_id does NOT
# cross-reference between /players and /fixtures/odds — see fetch_player_odds). Prints
# "<fixture_id>\t<start_date>\t<resolved_full_name>" on success, nothing on failure.
resolve_player_fixture() {
  local sport="$1" player="$2"
  local op_sport op_league page pid pname team_id found has_more
  read -r op_sport op_league <<< "$(map_sport "$sport")"
  [ "$op_league" = "-" ] && return 0
  pid=""; pname=""; team_id=""
  for page in $(seq 1 "$PLAYER_SEARCH_PAGES"); do
    curl -sS -H "X-Api-Key: $ODDSJAM_API_KEY" "$API_BASE/players?league=$op_league&page=$page" > "$TMP/players.json" || echo '{}' > "$TMP/players.json"
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
  if [ -z "$pid" ] || [ -z "$team_id" ]; then
    return 0
  fi
  curl -sS -H "X-Api-Key: $ODDSJAM_API_KEY" "$API_BASE/fixtures/active?team_id=$team_id&page=1" > "$TMP/pfixtures.json" || echo '{}' > "$TMP/pfixtures.json"
  jq -r --arg pname "$pname" '
    (.data // [])[0] | select(.!=null) | [.id, .start_date, $pname] | @tsv
  ' "$TMP/pfixtures.json" 2>/dev/null || true
}

# Fetches the core full-game lines (Moneyline/Spread/Total) for one book, writes the
# result (an array, possibly empty) to $TMP/odds.json.
fetch_team_odds() {
  local fid="$1" book="$2"
  curl -sS -G -H "X-Api-Key: $ODDSJAM_API_KEY" \
    --data-urlencode "fixture_id=$fid" \
    --data-urlencode "sportsbook=$book" \
    "$API_BASE/fixtures/odds" > "$TMP/odds_raw.json" || echo '{}' > "$TMP/odds_raw.json"
  # Two filters, both needed: market name, because "is_main" alone marks the primary
  # line *within whatever market it's on* (true for exotic/period props too); is_main,
  # because a core market also lists every alternate line.
  jq -c --argjson cap "$MAX_ODDS_PER_GAME" '
    [ (.data // [])[] | (.odds // [])[]
      | select(.is_main == true)
      | select(.market as $m | ["Moneyline","Point Spread","Spread","Total Points","Total","Game Total"] | index($m))
      | {sportsbook, market, selection: (if (.selection // "") == "" then (.name // "") else .selection end), price, points}
    ] | .[0:$cap]
  ' "$TMP/odds_raw.json" > "$TMP/odds.json" 2>/dev/null || echo "[]" > "$TMP/odds.json"
}

# Fetches a player prop's odds across up to several sharp books, writes the result (an
# array, possibly empty) to $TMP/odds.json.
fetch_player_odds() {
  local fid="$1" market="$2" pname="$3" sharp_books="$4"
  local -a all_books=() chunk=() sb_args=()
  while IFS= read -r sb; do all_books+=("$sb"); done < <(echo "$sharp_books" | jq -r '.[]')

  # Confirmed by direct test: this endpoint hard-caps at 5 sportsbooks per request.
  # Batch into chunks of <=5 and merge, so a 6th (or later) book never drops the others.
  : > "$TMP/odds_parts.jsonl"
  local i=0
  while [ "$i" -lt "${#all_books[@]}" ]; do
    chunk=("${all_books[@]:$i:5}")
    sb_args=()
    for sb in "${chunk[@]}"; do sb_args+=(--data-urlencode "sportsbook=$sb"); done
    curl -sS -G -H "X-Api-Key: $ODDSJAM_API_KEY" \
      --data-urlencode "fixture_id=$fid" \
      "${sb_args[@]}" \
      "$API_BASE/fixtures/odds" >> "$TMP/odds_parts.jsonl" || echo '{}' >> "$TMP/odds_parts.jsonl"
    echo >> "$TMP/odds_parts.jsonl"
    i=$((i + 5))
  done
  jq -s '{data: (map(.data // []) | add // [])}' "$TMP/odds_parts.jsonl" > "$TMP/odds_raw.json" 2>/dev/null || echo '{"data":[]}' > "$TMP/odds_raw.json"

  local kw_pattern name_kw exact_market nbooks
  kw_pattern=$(market_keywords "$market")
  # .selection is the BARE player name ("Tanner McKee"); .name is the full "Player
  # Over/Under Line" string. Match the player's last name against .selection
  # specifically (not .name, which would also match on every other word) to avoid
  # false hits.
  name_kw=$(echo "$pname" | awk '{print $NF}')
  exact_market=$(echo "player $market" | tr '[:upper:]' '[:lower:]')
  nbooks=$(echo "$sharp_books" | jq 'length')

  # Real market names follow a "Player <Stat>" convention for the full-game line, with
  # period/combo/alternate variants layered on top ("1st Half Player Passing Yards",
  # "Player Passing Yards (Combo)", "...H2H Spread", etc.) that also match the plain
  # keyword search — and each book posts a long tail of alternate point values for the
  # same market besides. Prefer the exact market name + is_main (the one line a book is
  # actually advertising); fall back to progressively looser matches, then collapse any
  # remaining alternate-line flood down to one per book/side closest to the pack's
  # midpoint — confirmed against real sample data (see search.js, same logic).
  jq -c --argjson cap "$MAX_ODDS_PER_GAME" --argjson nbooks "$nbooks" --arg kw "$kw_pattern" --arg nm "$name_kw" --arg exact "$exact_market" '
    [ (.data // [])[] | (.odds // [])[]
      | select((.selection // "") | test($nm; "i"))
      | {market: (.market // ""), price, points, is_main: (.is_main // false), sportsbook,
         selection: (if (.name // "") == "" then (.selection // "") else .name end)} ] as $all
    | ($all | map(select((.market|ascii_downcase)==$exact and .is_main==true))) as $m1
    | ($all | map(select((.market|ascii_downcase)==$exact))) as $m2
    | ($all | map(select((.market|test($kw; "i")) and .is_main==true))) as $m3
    | ($all | map(select(.market|test($kw; "i")))) as $m4
    | (if ($m1|length)>0 then $m1 elif ($m2|length)>0 then $m2 elif ($m3|length)>0 then $m3 else $m4 end) as $matched
    | (if ($matched|length) > ($nbooks*2) then
        $matched
        | group_by([.sportsbook, (if (.selection|test("under";"i")) then "Under" elif (.selection|test("over";"i")) then "Over" else "?" end)])
        | map(
            . as $g
            | ($g | map(.points) | map(select(.!=null))) as $pts
            | if ($pts|length)==0 then $g[0]
              else ($pts | add / length) as $mid | $g | min_by(((.points - $mid) * (.points - $mid)))
              end
          )
      else $matched end)
    | map({sportsbook, market, selection, price, points})
    | sort_by(.sportsbook) | .[0:$cap]
  ' "$TMP/odds_raw.json" > "$TMP/odds.json" 2>/dev/null || echo "[]" > "$TMP/odds.json"
}

count=$(jq '.bets | length' "$BETS")

for i in $(seq 0 $((count - 1))); do
  bet=$(jq -c ".bets[$i]" "$BETS")
  id=$(echo "$bet" | jq -r '.id')
  label=$(echo "$bet" | jq -r '.label')
  sport=$(echo "$bet" | jq -r '.sport')
  etype=$(echo "$bet" | jq -r '.type // "team"')
  status=$(echo "$bet" | jq -r '.status // "tracking"')

  if [ "$status" = "closed" ]; then
    echo "  [skip] \"$label\" already closed." >&2
    echo "$bet" >> "$TMP/bets_out.jsonl"
    continue
  fi

  fid=""; start=""; pname=""
  if [ "$etype" = "player_prop" ]; then
    player=$(echo "$bet" | jq -r '.player')
    echo "Resolving fixture for \"$label\" (player: $player)..." >&2
    line="$(resolve_player_fixture "$sport" "$player")"
    if [ -n "$line" ]; then
      fid=$(echo "$line" | cut -f1); start=$(echo "$line" | cut -f2); pname=$(echo "$line" | cut -f3)
    fi
  else
    team=$(echo "$bet" | jq -r '.team')
    echo "Resolving fixture for \"$label\" (team: $team)..." >&2
    line="$(resolve_team_fixture "$sport" "$team")"
    if [ -n "$line" ]; then
      fid=$(echo "$line" | cut -f1); start=$(echo "$line" | cut -f2)
    fi
  fi

  if [ -z "$fid" ]; then
    echo "  [debug] no fixture/player match yet for \"$label\"." >&2
    echo "$bet" | jq -c --arg err "No upcoming fixture matched yet — check the sport/team/player spelling, or it may just be too early." '.lastError = $err' >> "$TMP/bets_out.jsonl"
    continue
  fi

  start_epoch=$(date -u -d "$start" +%s 2>/dev/null || echo 0)

  if [ "$start_epoch" -gt 0 ] && [ "$NOW_EPOCH" -ge "$start_epoch" ]; then
    echo "  [close] \"$label\" fixture started at $start — locking closing line." >&2
    echo "$bet" | jq -c --arg ts "$NOW_ISO" --arg start "$start" '
      .status = "closed"
      | .fixtureStart = $start
      | .closingOdds = (.closingOdds // .liveOdds)
      | .closingCapturedAt = (.closingCapturedAt // .liveCapturedAt // $ts)
      | .lastError = (if .liveOdds == null then "Game started before any odds were captured." else null end)
    ' >> "$TMP/bets_out.jsonl"
    continue
  fi

  if [ "$etype" = "player_prop" ]; then
    market=$(echo "$bet" | jq -r '.market')
    sharp_books=$(echo "$bet" | jq -c '.sharpBooks // ["DraftKings","FanDuel","Novig","Kalshi","Pinnacle","Circa Sports"]')
    fetch_player_odds "$fid" "$market" "$pname" "$sharp_books"
  else
    book=$(echo "$bet" | jq -r '.placedBook // "DraftKings"')
    fetch_team_odds "$fid" "$book"
  fi

  matched=$(jq -r 'length' "$TMP/odds.json" 2>/dev/null || echo 0)

  if [ "$matched" = "0" ]; then
    echo "  [debug] fixture $fid matched for \"$label\" but no odds yet." >&2
    echo "$bet" | jq -c --arg start "$start" --arg err "Matched the fixture, but no odds posted for this yet — normal well before kickoff." '
      .fixtureStart = $start | .lastError = $err
    ' >> "$TMP/bets_out.jsonl"
    continue
  fi

  echo "  [ok] \"$label\" — $matched odds line(s) captured." >&2
  jq -n --slurpfile odds "$TMP/odds.json" --argjson bet "$bet" --arg ts "$NOW_ISO" --arg start "$start" '
    $bet
    | .fixtureStart = $start
    | .liveOdds = $odds[0]
    | .liveCapturedAt = $ts
    | .openingOdds = (.openingOdds // $odds[0])
    | .openingCapturedAt = (.openingCapturedAt // $ts)
    | .lastError = null
  ' >> "$TMP/bets_out.jsonl"
done

jq -s --arg ts "$NOW_ISO" '{updatedAt: $ts, bets: .}' "$TMP/bets_out.jsonl" > "$BETS"

echo "Updated $BETS" >&2
wc -c "$BETS" >&2
