import { HTTPError, response } from "./http.mjs";

export async function feedRoutes(c) {
  if (c.method !== "GET" || c.path.length !== 2 || c.path[0] !== "me" || c.path[1] !== "feed") return null;
  const before = c.url.searchParams.get("before");
  const cursor = before && /^(\d{1,16})\.([a-f0-9-]{36})$/u.exec(before);
  if (before && (!cursor || !Number.isSafeInteger(Number(cursor[1])))) throw new HTTPError(400, "The feed cursor is invalid.");
  const position = cursor ? [Number(cursor[1]), cursor[2]] : [Number.MAX_SAFE_INTEGER, ""];
  const events = await c.all(`WITH eligible AS (
    SELECT club_id FROM memberships WHERE account_id = ? AND state = 'active'
  ), events AS (
    SELECT activity.id, activity.club_id, activity.account_id, kind, label, activity.created_at, NULL AS read_id, NULL AS thread_id
    FROM eligible JOIN activity ON activity.club_id = eligible.club_id
    WHERE (activity.created_at, activity.id) < (?, ?)
    UNION ALL
    SELECT posts.id, reads.club_id, posts.author_id, 'post', reads.title, posts.created_at, reads.id, COALESCE(posts.checkpoint_id, 'general')
    FROM eligible JOIN reads ON reads.club_id = eligible.club_id JOIN posts ON posts.read_id = reads.id
    WHERE (posts.created_at, posts.id) < (?, ?)
  )
  SELECT events.id, events.club_id AS clubID, clubs.name AS clubName,
    COALESCE(memberships.display_name, accounts.name) AS memberName, kind, label, events.created_at AS createdAt,
    events.read_id AS readID, events.thread_id AS threadID
  FROM events JOIN clubs ON clubs.id = events.club_id
  LEFT JOIN accounts ON accounts.id = events.account_id
  LEFT JOIN memberships ON memberships.club_id = events.club_id AND memberships.account_id = events.account_id
  WHERE NOT EXISTS (SELECT 1 FROM blocks WHERE (account_id = ? AND blocked_id = events.account_id)
    OR (account_id = events.account_id AND blocked_id = ?))
  ORDER BY events.created_at DESC, events.id DESC LIMIT 41`, c.user, ...position, ...position, c.user, c.user);
  const hasMore = events.length > 40;
  if (hasMore) events.pop();
  return response({ events: events.map(({ readID, threadID, ...event }) => ({
    ...event, ...(readID ? { discussion: { clubID: event.clubID, readID, threadID, postID: event.id } } : {}),
  })), before: hasMore ? `${events.at(-1).createdAt}.${events.at(-1).id}` : null });
}
