// Writes a new (or updated) tracked bet directly into docs/bets.json on GitHub, via the
// GitHub Contents API, using a GitHub token kept server-side (never sent to the browser).
// This replaces the old "copy a JSON snippet, paste it into bets.json on GitHub, commit"
// flow with a single click from the app.
//
// POST /api/track   body: { bet: { id, label, type, sport, player, market, side, line,
//                                  placedBook, wageredOdds, sharpBooks } }
// -> { ok: true } or { error: "..." }
//
// Note: this endpoint is intentionally unauthenticated beyond the obscurity of this
// deployment's URL. docs/bets.json never holds stakes, P/L, or outcomes (those stay in
// the browser's localStorage) — only which games/props are being tracked and their
// odds — so the blast radius of someone finding this URL and spamming it is low, but it
// is a known, accepted tradeoff for keeping this a zero-login personal tool.

module.exports = async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") { res.status(200).end(); return; }
  if (req.method !== "POST") { res.status(405).json({ error: "POST only." }); return; }

  const token = process.env.GITHUB_TOKEN;
  const repo = process.env.GITHUB_REPO || "brandonjustice21/edge-ledger";
  const branch = process.env.GITHUB_BRANCH || "main";
  const path = "docs/bets.json";

  if (!token) { res.status(500).json({ error: "Server not configured (missing GITHUB_TOKEN)." }); return; }

  let body = req.body;
  if (typeof body === "string") {
    try { body = JSON.parse(body); } catch (e) { res.status(400).json({ error: "Invalid JSON body." }); return; }
  }
  const bet = body && body.bet;
  if (!bet || !bet.id || !bet.label) { res.status(400).json({ error: "bet with an id and label is required." }); return; }

  const apiUrl = "https://api.github.com/repos/" + repo + "/contents/" + path;
  const ghHeaders = {
    Authorization: "Bearer " + token,
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28"
  };

  try {
    const getResp = await fetch(apiUrl + "?ref=" + branch, { headers: ghHeaders });
    if (!getResp.ok) {
      const t = await getResp.text().catch(function () { return ""; });
      throw new Error("read " + getResp.status + (t ? ": " + t.slice(0, 200) : ""));
    }
    const file = await getResp.json();
    const current = JSON.parse(Buffer.from(file.content, "base64").toString("utf8"));
    const bets = current.bets || [];

    const normalized = Object.assign(
      { status: "tracking", openingOdds: null, liveOdds: null, closingOdds: null },
      bet
    );

    const idx = bets.findIndex(function (b) { return b.id === normalized.id; });
    if (idx === -1) bets.push(normalized);
    else bets[idx] = Object.assign({}, bets[idx], normalized);

    const updated = { updatedAt: current.updatedAt || null, bets: bets };
    const newContent = Buffer.from(JSON.stringify(updated, null, 2) + "\n", "utf8").toString("base64");

    const putResp = await fetch(apiUrl, {
      method: "PUT",
      headers: Object.assign({ "Content-Type": "application/json" }, ghHeaders),
      body: JSON.stringify({
        message: "Track bet: " + bet.label,
        content: newContent,
        sha: file.sha,
        branch: branch
      })
    });
    if (!putResp.ok) {
      const t = await putResp.text().catch(function () { return ""; });
      throw new Error("write " + putResp.status + (t ? ": " + t.slice(0, 200) : ""));
    }

    res.status(200).json({ ok: true, id: normalized.id });
  } catch (err) {
    res.status(502).json({ error: "GitHub " + (err && err.message ? err.message : String(err)) });
  }
};
