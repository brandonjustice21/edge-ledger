// Live player-prop odds lookup, proxied through this serverless function so the
// OddsJam/OpticOdds API key never reaches the browser (this site is public).
//
// GET /api/search?player=Mahomes&market=Passing%20Yards&sport=NFL
// -> { player, fixture: {id,start,home,away}, odds: [{sportsbook,market,selection,price,points}] }
// or { error: "..." } for an expected miss (no player/fixture/odds match yet).
//
// Mirrors the proven logic from .github/scripts/update_odds.sh's resolve_player_fixture +
// fetch_player_odds — same API quirks apply: player_id doesn't cross-reference between
// /players and /fixtures/odds (resolve via team_id instead), and /fixtures/odds caps out
// at 5 sportsbooks per request (chunk and merge).

const API_BASE = "https://api.opticodds.com/api/v3";
const PLAYER_SEARCH_PAGES = 50;
const MAX_ODDS = 40;

const SPORT_MAP = {
  NFL: ["football", "nfl"],
  NCAAF: ["football", "ncaaf"],
  NBA: ["basketball", "nba"],
  NCAAB: ["basketball", "ncaab"],
  MLB: ["baseball", "mlb"],
  NHL: ["hockey", "nhl"],
  Soccer: ["soccer", null],
  Tennis: ["tennis", null],
  Golf: ["golf", null],
  "MMA/Boxing": ["mma", null]
};

const MARKET_KEYWORDS = {
  "Points + Rebounds + Assists": /pra|pts\+reb\+ast|points \+ rebounds \+ assists/i,
  "Points + Rebounds": /pts\+reb|points \+ rebounds/i,
  "Points + Assists": /pts\+ast|points \+ assists/i,
  "Rebounds + Assists": /reb\+ast|rebounds \+ assists/i,
  "3-Pointers Made": /3-point|three/i,
  "Rebounds": /rebound/i,
  "Assists": /assist/i,
  "Steals": /steal/i,
  "Blocks": /block/i,
  "Turnovers": /turnover/i,
  "Passing Yards": /passing yard/i,
  "Rushing Yards": /rushing yard/i,
  "Receiving Yards": /receiving yard/i,
  "Receptions": /reception/i,
  "Passing Touchdowns": /passing touchdown|pass td/i,
  "Rushing Touchdowns": /rushing touchdown|rush td/i,
  "Touchdowns": /touchdown/i,
  "Strikeouts": /strikeout/i,
  "Home Runs": /home run/i,
  "Total Bases": /total base/i,
  "RBIs": /rbi/i,
  "Hits": /hit/i,
  "Shots on Goal": /shots on goal|shot on goal/i,
  "Saves": /save/i,
  "Goals": /goal/i,
  "Points": /point/i
};

const SHARP_BOOKS = ["DraftKings", "FanDuel", "Novig", "Kalshi", "Pinnacle", "Circa Sports"];

async function getJson(url, apiKey) {
  const r = await fetch(url, { headers: { "X-Api-Key": apiKey } });
  if (!r.ok) {
    const body = await r.text().catch(function () { return ""; });
    throw new Error("OddsJam " + r.status + (body ? ": " + body.slice(0, 200) : ""));
  }
  return r.json();
}

module.exports = async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") { res.status(200).end(); return; }

  const apiKey = process.env.ODDSJAM_API_KEY;
  if (!apiKey) { res.status(500).json({ error: "Server not configured (missing ODDSJAM_API_KEY)." }); return; }

  const player = (req.query.player || "").trim();
  const market = (req.query.market || "").trim();
  const sport = (req.query.sport || "").trim();

  if (!player || !sport) { res.status(400).json({ error: "player and sport are required." }); return; }

  const mapped = SPORT_MAP[sport];
  const opLeague = mapped ? mapped[1] : null;
  if (!opLeague) { res.status(400).json({ error: "Sport \"" + sport + "\" isn't a recognized league (e.g. NFL, NBA, MLB, NHL)." }); return; }

  try {
    let pid = null, pname = null, teamId = null, totalSeen = 0;
    for (let page = 1; page <= PLAYER_SEARCH_PAGES; page++) {
      const data = await getJson(API_BASE + "/players?league=" + opLeague + "&page=" + page, apiKey);
      const list = data.data || [];
      totalSeen += list.length;
      const found = list.find(function (p) {
        const name = (p.name || "").toLowerCase();
        const last = (p.last_name || "").toLowerCase();
        const q = player.toLowerCase();
        return name.indexOf(q) !== -1 || last.indexOf(q) !== -1;
      });
      if (found) { pid = found.id; pname = found.name; teamId = found.team && found.team.id; break; }
      if (!data.has_more) break;
    }

    if (!pid) {
      if (totalSeen === 0) {
        res.status(200).json({ error: "OddsJam has no player data for \"" + opLeague + "\" — likely a data-coverage gap on their end for this league." });
      } else {
        res.status(200).json({ error: "No " + opLeague + " player matched \"" + player + "\" (checked " + totalSeen + "). Check spelling." });
      }
      return;
    }
    if (!teamId) { res.status(200).json({ error: "Matched " + pname + " but the API didn't return a team for them." }); return; }

    const fx = await getJson(API_BASE + "/fixtures/active?team_id=" + teamId + "&page=1", apiKey);
    const fixture = (fx.data || [])[0];
    if (!fixture) { res.status(200).json({ error: "Matched " + pname + " but found no upcoming fixture for their team." }); return; }

    let allOdds = [];
    for (let i = 0; i < SHARP_BOOKS.length; i += 5) {
      const chunk = SHARP_BOOKS.slice(i, i + 5);
      const params = new URLSearchParams();
      params.set("fixture_id", fixture.id);
      chunk.forEach(function (b) { params.append("sportsbook", b); });
      const odds = await getJson(API_BASE + "/fixtures/odds?" + params.toString(), apiKey);
      const lines = (odds.data || []).reduce(function (acc, d) { return acc.concat(d.odds || []); }, []);
      allOdds = allOdds.concat(lines);
    }

    const kwPattern = market ? (MARKET_KEYWORDS[market] || new RegExp(market.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i")) : null;
    const nameKw = pname.split(" ").pop().toLowerCase();

    let matched = allOdds.filter(function (o) {
      const marketOk = !kwPattern || kwPattern.test(o.market || "");
      const nameOk = (o.selection || "").toLowerCase().indexOf(nameKw) !== -1;
      return marketOk && nameOk;
    });
    matched = matched
      .map(function (o) {
        return {
          sportsbook: o.sportsbook,
          market: o.market,
          selection: o.name || o.selection,
          price: o.price,
          points: o.points
        };
      })
      .sort(function (a, b) { return (a.sportsbook || "").localeCompare(b.sportsbook || ""); })
      .slice(0, MAX_ODDS);

    if (!matched.length) {
      res.status(200).json({
        player: pname,
        fixture: { id: fixture.id, start: fixture.start_date, home: fixture.home_team_display, away: fixture.away_team_display },
        odds: [],
        error: allOdds.length
          ? "Matched " + pname + "'s fixture, but no odds for market \"" + (market || "(any)") + "\" yet."
          : "Matched " + pname + "'s fixture, but these sharp books have posted no odds yet — normal well before kickoff."
      });
      return;
    }

    res.status(200).json({
      player: pname,
      fixture: { id: fixture.id, start: fixture.start_date, home: fixture.home_team_display, away: fixture.away_team_display },
      odds: matched
    });
  } catch (err) {
    res.status(502).json({ error: "OddsJam lookup failed: " + (err && err.message ? err.message : String(err)) });
  }
};
