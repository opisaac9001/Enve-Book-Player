import { HTTPError, passFilter, response, text } from "./http.mjs";

const activeMember = "EXISTS (SELECT 1 FROM memberships WHERE club_id = ? AND account_id = ? AND state = 'active')";
const matchingCheckpoint = "(? IS NULL OR EXISTS (SELECT 1 FROM checkpoints WHERE id = ? AND read_id = ?))";
const fields = `notes.id, notes.account_id AS authorID, COALESCE(memberships.display_name, accounts.name) AS authorName,
  notes.read_id AS readID, reads.club_id AS clubID, notes.book_title AS bookTitle, notes.checkpoint_id AS checkpointID,
  notes.body, notes.visibility, notes.created_at AS createdAt, notes.updated_at AS updatedAt`;
const joins = `FROM notes JOIN accounts ON accounts.id = notes.account_id LEFT JOIN reads ON reads.id = notes.read_id
  LEFT JOIN memberships ON memberships.account_id = notes.account_id AND memberships.club_id = reads.club_id`;

async function list(c, condition, ...args) {
  const before = c.url.searchParams.get("before");
  const cursor = before && /^(\d{1,16})\.([a-f0-9-]{36})$/u.exec(before);
  if (before && (!cursor || !Number.isSafeInteger(Number(cursor[1])))) throw new HTTPError(400, "The page cursor is invalid.");
  const notes = await c.all(`SELECT ${fields} ${joins}
    WHERE ${condition} AND (notes.created_at, notes.id) < (?, ?)
    ORDER BY notes.created_at DESC, notes.id DESC LIMIT 101`, ...args, cursor ? Number(cursor[1]) : Number.MAX_SAFE_INTEGER, cursor ? cursor[2] : "");
  const hasMore = notes.length > 100;
  if (hasMore) notes.pop();
  return response({ notes, before: hasMore ? `${notes.at(-1).createdAt}.${notes.at(-1).id}` : null });
}

async function draft(c) {
  const input = await c.body();
  const body = text(input.body, 3000);
  const visibility = input.visibility === undefined ? "private" : input.visibility;
  if (visibility !== "private" && visibility !== "club") throw new HTTPError(400, "Choose who can see the note.");
  if (visibility === "club") passFilter(c.env, body);
  const checkpoint = input.checkpointID == null ? null : text(input.checkpointID, 36);
  return { body, visibility, checkpoint };
}

export async function noteRoutes(c) {
  const [root, club, section, read, resource, id] = c.path;
  if (root === "me" && club === "notes") {
    if (!section && c.method === "GET") return list(c, "notes.account_id = ?", c.user);
    if (section && !read && c.method === "DELETE") {
      const removed = await c.run("DELETE FROM notes WHERE id = ? AND account_id = ?", section, c.user);
      if (!removed.meta.changes) throw new HTTPError(404, "This note is unavailable.");
      return response({ ok: true });
    }
    return null;
  }
  if (root !== "clubs" || !club || section !== "reads" || !read || resource !== "notes" || c.path.length > 6) return null;
  await c.requireMembership(club);
  await c.requireRead(club, read);
  if (!id && c.method === "GET") {
    return list(c, `notes.read_id = ? AND ${activeMember}
      AND (notes.account_id = ? OR (notes.visibility = 'club'
        AND (notes.checkpoint_id IS NULL OR ? OR EXISTS
          (SELECT 1 FROM completions WHERE checkpoint_id = notes.checkpoint_id AND account_id = ?))
        AND NOT EXISTS (SELECT 1 FROM blocks WHERE (account_id = ? AND blocked_id = notes.account_id)
          OR (account_id = notes.account_id AND blocked_id = ?))))`,
    read, club, c.user, c.user, Number(c.url.searchParams.get("revealSpoilers") === "true"), c.user, c.user, c.user);
  }
  if (!id && c.method === "POST") {
    const { body, visibility, checkpoint } = await draft(c);
    const noteID = crypto.randomUUID();
    const result = await c.run(`INSERT INTO notes (id, account_id, read_id, checkpoint_id, book_title, body, visibility, created_at, updated_at)
      SELECT ?, ?, id, ?, title, ?, ?, ?, ? FROM reads WHERE id = ? AND club_id = ? AND ${activeMember} AND ${matchingCheckpoint}`,
    noteID, c.user, checkpoint, body, visibility, c.now, c.now, read, club, club, c.user, checkpoint, checkpoint, read);
    if (!result.meta.changes) throw new HTTPError(404, "The read or checkpoint is unavailable.");
    return response({ id: noteID }, 201);
  }
  if (id && c.method === "PATCH") {
    const { body, visibility, checkpoint } = await draft(c);
    const result = await c.run(`UPDATE notes SET body = ?, visibility = ?, checkpoint_id = ?, updated_at = ?
      WHERE id = ? AND read_id = ? AND account_id = ? AND ${activeMember} AND ${matchingCheckpoint}`,
    body, visibility, checkpoint, c.now, id, read, c.user, club, c.user, checkpoint, checkpoint, read);
    if (!result.meta.changes) throw new HTTPError(404, "The note or checkpoint is unavailable.");
    return response({ ok: true });
  }
  if (id && c.method === "DELETE") {
    const result = await c.run(`DELETE FROM notes WHERE id = ? AND read_id = ? AND account_id = ? AND ${activeMember}`,
    id, read, c.user, club, c.user);
    if (!result.meta.changes) throw new HTTPError(404, "This note is unavailable.");
    return response({ ok: true });
  }
  return null;
}
