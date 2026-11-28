import { code, date, fraction, hash, HTTPError, normalizeCode, passFilter, response, text } from "./http.mjs";
import { hostedManifest } from "./hosted-copies.mjs";

const membership = `EXISTS (SELECT 1 FROM memberships WHERE club_id = ? AND account_id = ? AND state = 'active')`;
const owner = `EXISTS (SELECT 1 FROM clubs WHERE id = ? AND owner_id = ?)`;
const day = 86_400_000;

function checkpoint(input, env) {
  const label = text(input?.label, 100);
  const chapter = text(input?.chapterKey, 120, false);
  passFilter(env, label, chapter);
  return [label, chapter, date(input?.dueAt), input?.trackPosition == null ? null : fraction(input.trackPosition)];
}

function readMetadata(input, env) {
  const title = text(input.title, 160);
  const author = text(input.author, 120, false);
  const series = text(input.series, 120, false);
  passFilter(env, title, author, series);
  return [title, author, series];
}

async function detail(c, club) {
  const [clubRows, memberRows, readRows, activityRows, blockRows] = await c.batch([
    c.sql(`SELECT id, name, owner_id AS ownerID FROM clubs WHERE id = ? AND ${membership}`, club, club, c.user),
    c.sql(`SELECT accounts.id, COALESCE(display_name, accounts.name) AS name FROM memberships JOIN accounts ON accounts.id = account_id
      WHERE club_id = ? AND state = 'active' ORDER BY joined_at, account_id`, club),
    c.sql(`SELECT id, title, author, series, created_at AS createdAt, closed_at AS closedAt
      FROM reads WHERE club_id = ? ORDER BY closed_at IS NOT NULL, created_at DESC, id DESC`, club),
    c.sql(`SELECT activity.id, activity.account_id AS accountID, COALESCE(memberships.display_name, accounts.name) AS memberName,
      kind, label, created_at AS createdAt FROM activity LEFT JOIN accounts ON accounts.id = activity.account_id
      LEFT JOIN memberships ON memberships.club_id = activity.club_id AND memberships.account_id = activity.account_id
      WHERE activity.club_id = ? AND NOT EXISTS
      (SELECT 1 FROM blocks WHERE (account_id = ? AND blocked_id = activity.account_id) OR
       (blocked_id = ? AND account_id = activity.account_id)) ORDER BY created_at DESC, activity.id DESC LIMIT 60`, club, c.user, c.user),
    c.sql("SELECT blocked_id AS id FROM blocks WHERE account_id = ?", c.user),
  ]);
  const record = clubRows.results[0];
  if (!record) throw new HTTPError(404, "This club is unavailable.");
  return response({ ...record, members: memberRows.results, reads: readRows.results, activity: activityRows.results, blockedIDs: blockRows.results.map(({ id }) => id) });
}

async function readDetail(c, club, read) {
  const [readRows, steps, updates, completed, sharing] = await c.batch([
    c.sql(`SELECT id, title, author, series, created_at AS createdAt, closed_at AS closedAt FROM reads
      WHERE id = ? AND club_id = ? AND ${membership}`, read, club, club, c.user),
    c.sql(`SELECT id, label, chapter_key AS chapterKey, due_at AS dueAt, track_position AS trackPosition, sort_order AS sortOrder
      FROM checkpoints WHERE read_id = ? ORDER BY sort_order`, read),
    c.sql(`SELECT progress.account_id AS accountID, fraction, observed_at AS observedAt,
      CASE WHEN active_until > ? AND reads.closed_at IS NULL THEN active_until ELSE NULL END AS activeUntil
      FROM progress JOIN memberships ON memberships.account_id = progress.account_id AND memberships.club_id = ?
      JOIN reads ON reads.id = progress.read_id WHERE read_id = ? AND state = 'active'`, c.now, club, read),
    c.sql(`SELECT completions.account_id AS accountID, checkpoint_id AS checkpointID, completed_at AS completedAt
      FROM completions JOIN checkpoints ON checkpoints.id = checkpoint_id
      JOIN memberships ON memberships.account_id = completions.account_id AND memberships.club_id = ?
      WHERE checkpoints.read_id = ? AND state = 'active'`, club, read),
    c.sql("SELECT epoch, presence FROM sharing WHERE read_id = ? AND account_id = ?", read, c.user),
  ]);
  if (!readRows.results[0]) throw new HTTPError(404, "This club read is unavailable.");
  const settings = sharing.results[0];
  return response({ read: readRows.results[0], checkpoints: steps.results, progress: updates.results, completions: completed.results,
    sharing: settings ? { epoch: settings.epoch, presence: Boolean(settings.presence) } : null,
    ...(c.env.CLUB_MEDIA ? { hostedCopy: await hostedManifest(c, read) } : {}) });
}

async function postRead(c, club) {
  await c.requireMembership(club, true);
  const input = await c.body();
  const [title, author, series] = readMetadata(input, c.env);
  if (!Array.isArray(input.checkpoints) || input.checkpoints.length > 24) throw new HTTPError(400, "Add up to 24 checkpoints.");
  const checkpoints = input.checkpoints.map((entry) => checkpoint(entry, c.env));
  if (input.pollID != null && typeof input.pollID !== "string") throw new HTTPError(400, "Choose a finished poll.");
  if (input.pollID) {
    const poll = await c.first(`SELECT nominations.name, nominations.author FROM polls JOIN nominations ON nominations.id = winner_id
      WHERE polls.id = ? AND polls.club_id = ? AND closed_at IS NOT NULL AND started_read_id IS NULL`, input.pollID, club);
    if (!poll || title !== poll.name || author !== poll.author) throw new HTTPError(409, "This poll does not have an unused winning book.");
  }
  const id = crypto.randomUUID();
  const pollGuard = input.pollID ? " AND EXISTS (SELECT 1 FROM polls WHERE id = ? AND club_id = ? AND closed_at IS NOT NULL AND started_read_id IS NULL)" : "";
  const pollArgs = input.pollID ? [input.pollID, club] : [];
  const results = await c.batch([
    c.sql(`UPDATE reads SET closed_at = ? WHERE club_id = ? AND closed_at IS NULL AND ${owner}${pollGuard}`, c.now, club, club, c.user, ...pollArgs),
    c.sql(`INSERT INTO reads (id, club_id, title, author, series, created_at) SELECT ?, ?, ?, ?, ?, ? WHERE ${owner}${pollGuard}`,
      id, club, title, author, series, c.now, club, c.user, ...pollArgs),
    ...checkpoints.map(([label, chapter, due, position], order) => c.sql(`INSERT INTO checkpoints (id, read_id, sort_order, label, chapter_key, due_at, track_position)
      SELECT ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM reads WHERE id = ?)`,
      crypto.randomUUID(), id, order, label, chapter, due, position, id)),
    ...(input.pollID ? [c.sql("UPDATE polls SET started_read_id = ? WHERE id = ? AND EXISTS (SELECT 1 FROM reads WHERE id = ?)", id, input.pollID, id)] : []),
    c.sql(`INSERT INTO activity SELECT ?, ?, ?, 'readStarted', ?, ? WHERE EXISTS (SELECT 1 FROM reads WHERE id = ?)`,
      crypto.randomUUID(), club, c.user, title, c.now, id),
  ]);
  if (!results[1].meta.changes) throw new HTTPError(409, "The club changed. Refresh and try again.");
  return response({ id }, 201);
}

async function readAction(c, club, read, action, id) {
  if (c.method === "GET" && !action) return readDetail(c, club, read);
  if (action === "sharing" && c.method === "PUT" && !id) {
    await c.requireMembership(club);
    await c.requireRead(club, read, true);
    const input = await c.body();
    if (typeof input.enabled !== "boolean" || typeof input.presence !== "boolean") throw new HTTPError(400, "Choose a sharing setting.");
    if (!input.enabled) {
      await c.batch([
        c.sql("DELETE FROM sharing WHERE read_id = ? AND account_id = ?", read, c.user),
        c.sql("DELETE FROM progress WHERE read_id = ? AND account_id = ?", read, c.user),
      ]);
      return response({ epoch: null, presence: false });
    }
    const epoch = crypto.randomUUID();
    const results = await c.batch([
      c.sql(`INSERT INTO sharing SELECT ?, ?, ?, ? WHERE ${membership} AND EXISTS (SELECT 1 FROM reads WHERE id = ? AND closed_at IS NULL)
        ON CONFLICT(read_id, account_id) DO UPDATE SET epoch = excluded.epoch, presence = excluded.presence`,
      read, c.user, epoch, Number(input.presence), club, c.user, read),
      c.sql("UPDATE progress SET active_until = NULL WHERE read_id = ? AND account_id = ?", read, c.user),
    ]);
    if (!results[0].meta.changes) throw new HTTPError(409, "This read changed. Refresh the club.");
    return response({ epoch, presence: input.presence });
  }
  if (action === "progress" && c.method === "PUT" && !id) {
    await c.requireMembership(club);
    await c.requireRead(club, read, true);
    const input = await c.body();
    const position = fraction(input.fraction);
    const observed = date(input.observedAt);
    const epoch = text(input.epoch, 36);
    if (observed == null || observed > c.now + 120_000 || typeof input.active !== "boolean") throw new HTTPError(400, "The progress time is invalid.");
    if (!await c.first("SELECT 1 FROM sharing WHERE read_id = ? AND account_id = ? AND epoch = ?", read, c.user, epoch)) {
      throw new HTTPError(409, "Progress sharing changed. Choose your sharing settings again.");
    }
    const activeUntil = input.active && observed > c.now - 90_000 ? c.now + 90_000 : null;
    await c.run(`INSERT INTO progress SELECT ?, ?, ?, ?, CASE WHEN presence = 1 THEN ? ELSE NULL END FROM sharing
      WHERE read_id = ? AND account_id = ? AND epoch = ? AND ${membership}
      AND EXISTS (SELECT 1 FROM reads WHERE id = ? AND closed_at IS NULL)
      ON CONFLICT(read_id, account_id) DO UPDATE SET fraction = excluded.fraction, observed_at = excluded.observed_at,
      active_until = excluded.active_until WHERE excluded.observed_at > progress.observed_at`,
      read, c.user, position, observed, activeUntil, read, c.user, epoch, club, c.user, read);
    return response({ ok: true });
  }
  if (action === "checkpoints" && c.method === "POST" && !id) {
    await c.requireMembership(club, true);
    await c.requireRead(club, read, true);
    const [label, chapter, due, position] = checkpoint(await c.body(), c.env);
    const newID = crypto.randomUUID();
    const result = await c.run(`INSERT INTO checkpoints (id, read_id, sort_order, label, chapter_key, due_at, track_position)
      SELECT ?, ?, (SELECT COALESCE(MAX(sort_order) + 1, 0) FROM checkpoints WHERE read_id = ?), ?, ?, ?, ?
      WHERE ${owner} AND EXISTS (SELECT 1 FROM reads WHERE id = ? AND closed_at IS NULL)
      AND (SELECT count(*) FROM checkpoints WHERE read_id = ?) < 24`,
      newID, read, read, label, chapter, due, position, club, c.user, read, read);
    if (!result.meta.changes) throw new HTTPError(409, "This read changed or already has 24 checkpoints.");
    await c.activity(club, "planChanged", "Added a checkpoint").run();
    return response({ id: newID }, 201);
  }
  if (action === "checkpoints" && c.method === "PATCH" && id) {
    await c.requireMembership(club, true);
    await c.requireRead(club, read, true);
    const input = await c.body();
    const label = text(input.label, 100);
    passFilter(c.env, label);
    const result = await c.run(`UPDATE checkpoints SET label = ?, due_at = ? WHERE id = ? AND read_id = ?
      AND ${owner} AND EXISTS (SELECT 1 FROM reads WHERE id = ? AND closed_at IS NULL)`, label, date(input.dueAt), id, read, club, c.user, read);
    if (!result.meta.changes) throw new HTTPError(404, "This checkpoint is unavailable.");
    await c.activity(club, "planChanged", "Updated a checkpoint").run();
    return response({ ok: true });
  }
  return null;
}

async function complete(c, club, read, id) {
  await c.requireMembership(club);
  await c.requireRead(club, read, true);
  const step = await c.first("SELECT sort_order AS sortOrder, label FROM checkpoints WHERE id = ? AND read_id = ?", id, read);
  if (!step) throw new HTTPError(404, "This checkpoint is unavailable.");
  const input = await c.body();
  const epoch = text(input.epoch, 36, false);
  const guard = epoch ? " AND EXISTS (SELECT 1 FROM sharing WHERE read_id = ? AND account_id = ? AND epoch = ?)" : "";
  const args = epoch ? [read, c.user, epoch] : [];
  if (epoch && !await c.first("SELECT 1 FROM sharing WHERE read_id = ? AND account_id = ? AND epoch = ?", ...args)) {
    throw new HTTPError(409, "Progress sharing changed.");
  }
  await c.batch([
    c.sql(`INSERT INTO activity SELECT ?, ?, ?, 'checkpoint', ?, ? WHERE ${membership}
      AND NOT EXISTS (SELECT 1 FROM completions WHERE checkpoint_id = ? AND account_id = ?)
      AND EXISTS (SELECT 1 FROM reads WHERE id = ? AND closed_at IS NULL)${guard}`,
      crypto.randomUUID(), club, c.user, step.label, c.now, club, c.user, id, c.user, read, ...args),
    c.sql(`INSERT OR IGNORE INTO completions SELECT id, ?, ? FROM checkpoints WHERE read_id = ? AND sort_order <= ?
      AND ${membership} AND EXISTS (SELECT 1 FROM reads WHERE id = ? AND closed_at IS NULL)${guard}`, c.user, c.now, read, step.sortOrder, club, c.user, read, ...args),
  ]);
  return response({ ok: true });
}

export async function clubRoutes(c) {
  const [route, club, section, id, action, target, operation] = c.path;
  if (route === "blocks" && club && c.path.length === 2 && ["PUT", "DELETE"].includes(c.method)) {
    if (club === c.user) throw new HTTPError(400, "Choose another member.");
    if (c.method === "PUT") await c.run("INSERT OR IGNORE INTO blocks SELECT ?, id FROM accounts WHERE id = ?", c.user, club);
    else await c.run("DELETE FROM blocks WHERE account_id = ? AND blocked_id = ?", c.user, club);
    return response({ ok: true });
  }
  if (route !== "clubs") return null;
  if (!club && c.method === "GET") {
    const summaries = await c.all(`SELECT clubs.id, clubs.name, owner_id AS ownerID,
        reads.id AS currentReadID, reads.title AS currentTitle, reads.author AS currentAuthor,
        next.label AS nextLabel, next.due_at AS nextDueAt
      FROM memberships JOIN clubs ON clubs.id = memberships.club_id
      LEFT JOIN reads ON reads.club_id = clubs.id AND reads.closed_at IS NULL
      LEFT JOIN checkpoints AS next ON next.id = (
        SELECT checkpoints.id FROM checkpoints WHERE checkpoints.read_id = reads.id
        AND NOT EXISTS (SELECT 1 FROM completions WHERE checkpoint_id = checkpoints.id AND account_id = memberships.account_id)
        ORDER BY sort_order LIMIT 1
      )
      WHERE memberships.account_id = ? AND memberships.state = 'active' ORDER BY clubs.name, clubs.id`, c.user);
    return response(summaries.map(({ nextLabel, nextDueAt, ...club }) => ({
      ...club, nextCheckpoint: nextLabel == null ? null : { label: nextLabel, dueAt: nextDueAt },
    })));
  }
  if (!club && c.method === "POST") {
    const input = await c.body();
    const name = text(input.name, 72);
    passFilter(c.env, name);
    const id = crypto.randomUUID();
    const statements = [
      c.sql("INSERT INTO clubs VALUES (?, ?, ?, ?)", id, name, c.user, c.now),
      c.sql("INSERT INTO memberships (club_id, account_id, joined_at, state) VALUES (?, ?, ?, 'active')", id, c.user, c.now),
    ];
    if (input.read != null) {
      const [title, author, series] = readMetadata(input.read, c.env);
      const stages = input.read.checkpoints;
      if (!Array.isArray(stages) || stages.length > 24) throw new HTTPError(400, "Add up to 24 checkpoints.");
      const readID = crypto.randomUUID();
      statements.push(c.sql("INSERT INTO reads (id, club_id, title, author, series, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        readID, id, title, author, series, c.now));
      for (const [order, entry] of stages.entries()) {
        statements.push(c.sql(`INSERT INTO checkpoints (id, read_id, sort_order, label, chapter_key, due_at, track_position)
          VALUES (?, ?, ?, ?, ?, ?, ?)`, crypto.randomUUID(), readID, order, ...checkpoint(entry, c.env)));
      }
      statements.push(c.activity(id, "readStarted", title));
    }
    await c.batch(statements);
    return response({ id }, 201);
  }
  if (club === "join" && !section && c.method === "POST") {
    await c.rateLimit("join", c.user, 20, 3_600_000);
    const input = await c.body();
    const key = await hash(normalizeCode(input.code, 10));
    const name = input.name === undefined ? null : text(input.name, 36);
    if (name && /[\t\r\n]/u.test(name)) throw new HTTPError(400, "Enter a display name on one line.");
    passFilter(c.env, name);
    const match = await c.first(`INSERT INTO memberships (club_id, account_id, joined_at, state, display_name)
      SELECT club_id, ?, ?, 'active', ? FROM invites WHERE code_hash = ? AND expires_at > ?
      ON CONFLICT(club_id, account_id) DO UPDATE SET state = 'active',
      joined_at = CASE WHEN state = 'left' THEN excluded.joined_at ELSE joined_at END,
      display_name = COALESCE(excluded.display_name, memberships.display_name)
      WHERE state <> 'removed' RETURNING club_id AS id`, c.user, c.now, name, key, c.now);
    if (!match) throw new HTTPError(404, "This invitation is unavailable.");
    return response(match);
  }
  if (!club) return null;
  if (!section && c.method === "GET") return detail(c, club);
  if (section === "invite" && !id && ["POST", "DELETE"].includes(c.method)) {
    await c.requireMembership(club, true);
    if (c.method === "DELETE") {
      await c.run(`DELETE FROM invites WHERE club_id = ? AND ${owner}`, club, club, c.user);
      return response({ ok: true });
    }
    const invite = code(10);
    const expiresAt = c.now + 7 * day;
    const result = await c.run(`INSERT INTO invites SELECT ?, ?, ? WHERE ${owner}
      ON CONFLICT(club_id) DO UPDATE SET code_hash = excluded.code_hash, expires_at = excluded.expires_at`,
      club, await hash(invite), expiresAt, club, c.user);
    if (!result.meta.changes) throw new HTTPError(403, "Only the host can do that.");
    return response({ code: invite, expiresAt });
  }
  if (section === "leave" && !id && c.method === "POST") {
    const record = await c.requireMembership(club);
    if (record.ownerID === c.user) throw new HTTPError(409, "Pass hosting to another member before leaving, or delete the club.");
    return removeMember(c, club, c.user, "left");
  }
  if (section === "members" && id && !action && c.method === "DELETE") {
    await c.requireMembership(club, true);
    if (id === c.user) throw new HTTPError(400, "Pass hosting to another member first.");
    return removeMember(c, club, id, "removed");
  }
  if (section === "host" && !id && c.method === "PUT") {
    await c.requireMembership(club, true);
    const next = text((await c.body()).memberID, 36);
    const updated = await c.run(`UPDATE clubs SET owner_id = ? WHERE id = ? AND owner_id = ? AND ${membership}`, next, club, c.user, club, next);
    if (!updated.meta.changes) throw new HTTPError(409, "Choose an active member.");
    return response({ ok: true });
  }
  if (!section && c.method === "DELETE") {
    await c.requireMembership(club, true);
    await c.run("DELETE FROM clubs WHERE id = ? AND owner_id = ?", club, c.user);
    return response({ ok: true });
  }
  if (section !== "reads") return null;
  if (!id && c.method === "POST") return postRead(c, club);
  if (!id) return null;
  if (action === "checkpoints" && target && operation === "complete" && c.method === "PUT" && c.path.length === 7) return complete(c, club, id, target);
  if (operation) return null;
  return readAction(c, club, id, action, target);
}

async function removeMember(c, club, accountID, state) {
  const authority = state === "removed" ? owner : "EXISTS (SELECT 1 FROM clubs WHERE id = ? AND owner_id <> ?)";
  const reads = "SELECT id FROM reads WHERE club_id = ?";
  const results = await c.batch([
    c.sql(`UPDATE memberships SET state = ? WHERE club_id = ? AND account_id = ? AND state = 'active' AND ${authority}`,
      state, club, accountID, club, c.user),
    c.sql(`DELETE FROM sharing WHERE account_id = ? AND read_id IN (${reads}) AND ${authority}`, accountID, club, club, c.user),
    c.sql(`DELETE FROM progress WHERE account_id = ? AND read_id IN (${reads}) AND ${authority}`, accountID, club, club, c.user),
  ]);
  if (!results[0].meta.changes) throw new HTTPError(404, "This membership is unavailable.");
  return response({ ok: true });
}
