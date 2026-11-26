import { date, HTTPError, passFilter, response, text } from "./http.mjs";

const owner = `EXISTS (SELECT 1 FROM clubs WHERE id = ? AND owner_id = ?)`;
const member = `EXISTS (SELECT 1 FROM memberships WHERE club_id = ? AND account_id = ? AND state = 'active')`;

async function nextUp(c, club) {
  const [membership, nominations, polls, options, votes] = await c.batch([
    c.sql(`SELECT 1 WHERE ${member}`, club, c.user),
    c.sql(`SELECT nominations.id, nominations.name, author, nominations.account_id AS accountID,
      COALESCE(memberships.display_name, accounts.name) AS memberName, created_at AS createdAt
      FROM nominations LEFT JOIN accounts ON accounts.id = nominations.account_id
      LEFT JOIN memberships ON memberships.club_id = nominations.club_id AND memberships.account_id = nominations.account_id
      WHERE nominations.club_id = ? ORDER BY created_at DESC, nominations.id DESC`, club),
    c.sql(`SELECT id, name, created_at AS createdAt, closes_at AS closesAt, closed_at AS closedAt, winner_id AS winnerID,
      started_read_id AS startedReadID FROM polls WHERE club_id = ? ORDER BY created_at DESC, id DESC`, club),
    c.sql(`SELECT poll_id AS pollID, nomination_id AS nominationID FROM poll_options JOIN polls ON polls.id = poll_id WHERE club_id = ?`, club),
    c.sql(`SELECT poll_id AS pollID, nomination_id AS nominationID, votes.account_id AS accountID,
      COALESCE(memberships.display_name, accounts.name) AS memberName
      FROM votes JOIN polls ON polls.id = poll_id JOIN accounts ON accounts.id = votes.account_id
      LEFT JOIN memberships ON memberships.club_id = polls.club_id AND memberships.account_id = votes.account_id
      WHERE polls.club_id = ?`, club),
  ]);
  if (!membership.results.length) throw new HTTPError(404, "This club is unavailable.");
  const byPoll = (rows) => {
    const grouped = new Map();
    for (const { pollID, ...row } of rows) {
      if (!grouped.has(pollID)) grouped.set(pollID, []);
      grouped.get(pollID).push(row);
    }
    return grouped;
  };
  const choices = byPoll(options.results);
  const ballots = byPoll(votes.results);
  return response({ nominations: nominations.results, polls: polls.results.map((poll) => ({ ...poll,
    optionIDs: (choices.get(poll.id) ?? []).map(({ nominationID }) => nominationID), votes: ballots.get(poll.id) ?? [],
  })) });
}

async function createPoll(c, club) {
  await c.requireMembership(club, true);
  const input = await c.body();
  const name = text(input.name, 100);
  const closes = date(input.closesAt);
  passFilter(c.env, name);
  if (!Array.isArray(input.optionIDs) || input.optionIDs.length < 2 || input.optionIDs.length > 12 ||
    input.optionIDs.some((value) => typeof value !== "string" || value.length !== 36) || new Set(input.optionIDs).size !== input.optionIDs.length) {
    throw new HTTPError(400, "Choose between 2 and 12 different nominations.");
  }
  if (closes != null && closes <= c.now) throw new HTTPError(400, "Choose a closing date in the future.");
  const placeholders = input.optionIDs.map(() => "?").join(",");
  const nominated = await c.first(`SELECT count(*) AS count FROM nominations WHERE club_id = ? AND id IN (${placeholders})`, club, ...input.optionIDs);
  if (nominated.count !== input.optionIDs.length) throw new HTTPError(400, "Choose nominations from this club.");
  const id = crypto.randomUUID();
  const results = await c.batch([
    c.sql(`INSERT INTO polls (id, club_id, name, created_at, closes_at) SELECT ?, ?, ?, ?, ? WHERE ${owner}
      AND NOT EXISTS (SELECT 1 FROM polls WHERE club_id = ? AND closed_at IS NULL)`, id, club, name, c.now, closes, club, c.user, club),
    ...input.optionIDs.map((nomination) => c.sql("INSERT INTO poll_options SELECT ?, ? WHERE EXISTS (SELECT 1 FROM polls WHERE id = ?)", id, nomination, id)),
  ]);
  if (!results[0].meta.changes) throw new HTTPError(409, "Close the current poll before starting another.");
  return response({ id }, 201);
}

async function vote(c, club, id) {
  await c.requireMembership(club);
  const nomination = text((await c.body()).nominationID, 36);
  const result = await c.run(`INSERT INTO votes (poll_id, nomination_id, account_id)
    SELECT ?, ?, ? FROM polls JOIN poll_options ON poll_options.poll_id = polls.id WHERE polls.id = ? AND club_id = ?
    AND nomination_id = ? AND closed_at IS NULL AND (closes_at IS NULL OR closes_at > ?) AND ${member}
    ON CONFLICT(poll_id, account_id) DO UPDATE SET nomination_id = excluded.nomination_id`, id, nomination, c.user, id, club, nomination, c.now, club, c.user);
  if (!result.meta.changes) throw new HTTPError(409, "This poll or option is unavailable.");
  return response({ ok: true });
}

async function closePoll(c, club, id) {
  await c.requireMembership(club, true);
  const preferred = text((await c.body()).winnerID, 36, false);
  const results = await c.all(`SELECT poll_options.nomination_id AS id, count(votes.account_id) AS votes
    FROM poll_options JOIN polls ON polls.id = poll_options.poll_id LEFT JOIN votes ON votes.poll_id = polls.id
    AND votes.nomination_id = poll_options.nomination_id WHERE polls.id = ? AND club_id = ? AND closed_at IS NULL
    GROUP BY poll_options.nomination_id ORDER BY votes DESC, poll_options.nomination_id`, id, club);
  if (!results.length) throw new HTTPError(404, "This poll is unavailable.");
  const tied = results.filter((result) => result.votes === results[0].votes);
  const winner = tied.length === 1 ? tied[0].id : preferred;
  if (!tied.some((option) => option.id === winner)) throw new HTTPError(409, "Choose one of the tied books.");
  const updated = await c.batch([
    c.sql(`UPDATE polls SET closed_at = ?, winner_id = ? WHERE id = ? AND club_id = ? AND closed_at IS NULL AND ${owner}
      AND NOT EXISTS (SELECT 1 FROM poll_options po WHERE po.poll_id = polls.id AND
        (SELECT count(*) FROM votes WHERE poll_id = polls.id AND nomination_id = po.nomination_id) >
        (SELECT count(*) FROM votes WHERE poll_id = polls.id AND nomination_id = ?))`, c.now, winner, id, club, club, c.user, winner),
    c.sql(`INSERT INTO activity SELECT ?, ?, ?, 'pollClosed', name, ? FROM polls WHERE id = ? AND closed_at = ? AND winner_id = ?`,
      crypto.randomUUID(), club, c.user, c.now, id, c.now, winner),
  ]);
  if (!updated[0].meta.changes) throw new HTTPError(409, "The poll changed. Refresh and try again.");
  return response({ ok: true });
}

export async function pollRoutes(c) {
  const [root, club, section, id, action] = c.path;
  if (root !== "clubs" || !club || c.path.length > 5) return null;
  if (section === "next" && !id && c.method === "GET") return nextUp(c, club);
  if (section === "nominations" && !id && c.method === "POST") {
    await c.requireMembership(club);
    const input = await c.body();
    const name = text(input.name, 160);
    const author = text(input.author, 120, false);
    passFilter(c.env, name, author);
    const newID = crypto.randomUUID();
    const result = await c.run(`INSERT INTO nominations SELECT ?, ?, ?, ?, ?, ? WHERE ${member}
      AND NOT EXISTS (SELECT 1 FROM nominations WHERE club_id = ? AND name = ? COLLATE NOCASE AND author IS ? COLLATE NOCASE)`,
      newID, club, name, author, c.user, c.now, club, c.user, club, name, author);
    if (!result.meta.changes) throw new HTTPError(409, "This book has already been nominated, or your membership changed.");
    return response({ id: newID }, 201);
  }
  if (section !== "polls") return null;
  if (!id && c.method === "POST") return createPoll(c, club);
  if (id && action === "vote" && c.method === "PUT") return vote(c, club, id);
  if (id && action === "close" && c.method === "POST") return closePoll(c, club, id);
  return null;
}
