import { HTTPError, passFilter, response, text } from "./http.mjs";

const emojis = new Set(["\u2764\ufe0f", "\ud83d\ude02", "\ud83d\ude2e", "\ud83d\udc4f", "\ud83d\udcda"]);
const activeMember = `EXISTS (SELECT 1 FROM memberships WHERE club_id = ? AND account_id = ? AND state = 'active')`;
const visible = `NOT EXISTS (SELECT 1 FROM blocks WHERE (account_id = ? AND blocked_id = posts.author_id) OR
  (blocked_id = ? AND account_id = posts.author_id))`;
const reactionsVisible = `NOT EXISTS (SELECT 1 FROM blocks WHERE
  (account_id = ? AND blocked_id = reactions.account_id) OR (blocked_id = ? AND account_id = reactions.account_id))`;
const postFields = `posts.id, posts.author_id AS authorID, COALESCE(memberships.display_name, accounts.name) AS authorName,
  posts.parent_id AS parentID, posts.body, posts.passage, posts.passage_chapter AS passageChapter,
  posts.created_at AS createdAt, posts.is_spoiler AS isSpoiler`;
const postAuthors = `FROM posts JOIN accounts ON accounts.id = posts.author_id
  LEFT JOIN memberships ON memberships.club_id = ? AND memberships.account_id = posts.author_id`;
const promptOwner = `EXISTS (SELECT 1 FROM reads JOIN clubs ON clubs.id = reads.club_id
  WHERE reads.id = ? AND reads.club_id = ? AND clubs.owner_id = ? AND reads.closed_at IS NULL)`;

async function checkpointFor(c, read, thread) {
  if (thread === "general") return null;
  if (!await c.first("SELECT 1 FROM checkpoints WHERE id = ? AND read_id = ?", thread, read)) {
    throw new HTTPError(404, "This discussion is unavailable.");
  }
  return thread;
}

function presentedPost(post, reactions, viewer, revealed = false) {
  const isSpoiler = Boolean(post.isSpoiler);
  const concealed = isSpoiler && post.authorID !== viewer && !revealed;
  return { ...post, isSpoiler, concealed,
    ...(concealed ? { body: "", passage: null, passageChapter: null } : {}), reactions };
}

async function discussion(c, club, read, thread) {
  await c.requireMembership(club);
  const state = await c.requireRead(club, read, c.method === "POST");
  const checkpoint = await checkpointFor(c, read, thread);
  if (c.method === "GET") {
    const before = c.url.searchParams.get("before") ?? "";
    const focus = c.url.searchParams.get("focus");
    if (focus !== null && !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/u.test(focus)) {
      throw new HTTPError(400, "The discussion post ID is invalid.");
    }
    const source = /^(\d{1,16})\.([a-f0-9-]{36})$/u.exec(before);
    if (before && !source) throw new HTTPError(400, "The page cursor is invalid.");
    const cursor = source ? [Number(source[1]), source[2]] : [Number.MAX_SAFE_INTEGER, ""];
    const [scope, page, reactionRows, prompts, focusedRows] = await c.batch([
      c.sql(`SELECT 1 WHERE ${activeMember}`, club, c.user),
      c.sql(`SELECT ${postFields} ${postAuthors}
        WHERE posts.read_id = ? AND posts.checkpoint_id IS ? AND (posts.created_at, posts.id) < (?, ?) AND ${visible}
        ORDER BY created_at DESC, posts.id DESC LIMIT 41`, club, read, checkpoint, ...cursor, c.user, c.user),
      c.sql(`SELECT reactions.post_id AS postID, reactions.emoji, reactions.account_id AS accountID FROM reactions
        JOIN posts ON posts.id = reactions.post_id WHERE (posts.id IN (SELECT posts.id FROM posts
        WHERE read_id = ? AND checkpoint_id IS ? AND (created_at, posts.id) < (?, ?) AND ${visible}
        ORDER BY created_at DESC, posts.id DESC LIMIT 40)
        OR (posts.id = ? AND posts.read_id = ? AND posts.checkpoint_id IS ? AND ${visible})) AND ${reactionsVisible}`,
        read, checkpoint, ...cursor, c.user, c.user, focus, read, checkpoint, c.user, c.user, c.user, c.user),
      c.sql("SELECT body, updated_at AS updatedAt FROM discussion_prompts WHERE read_id = ? AND thread_id = ?", read, thread),
      ...(focus ? [c.sql(`SELECT ${postFields} ${postAuthors}
        WHERE posts.id = ? AND posts.read_id = ? AND posts.checkpoint_id IS ? AND ${visible}`,
        club, focus, read, checkpoint, c.user, c.user)] : []),
    ]);
    if (!scope.results.length) throw new HTTPError(404, "This club is unavailable.");
    const reactions = new Map();
    for (const { postID, ...reaction } of reactionRows.results) {
      if (!reactions.has(postID)) reactions.set(postID, []);
      reactions.get(postID).push(reaction);
    }
    const posts = page.results.slice(0, 40).map((post) => presentedPost(post, reactions.get(post.id) ?? [], c.user));
    const last = posts.at(-1);
    const focused = focusedRows?.results[0];
    return response({ posts, before: page.results.length > posts.length ? `${last.createdAt}.${last.id}` : null,
      archived: state.closedAt != null, discussionTools: true, prompt: prompts.results[0] ?? null,
      ...(focus ? { focusedPost: focused ? presentedPost(focused, reactions.get(focused.id) ?? [], c.user) : null } : {}) });
  }
  if (c.method === "POST") {
    const input = await c.body();
    const body = text(input.body, 3000, false);
    const passage = text(input.passage, 600, false);
    const chapter = passage ? text(input.passageChapter, 120, false) : null;
    const parent = text(input.parentID, 36, false);
    if (input.isSpoiler !== undefined && typeof input.isSpoiler !== "boolean") throw new HTTPError(400, "Choose a spoiler setting.");
    if (!body && !passage) throw new HTTPError(400, "Write a post or add a short passage.");
    passFilter(c.env, body, passage, chapter);
    const original = parent && await c.first(`SELECT is_spoiler AS isSpoiler
      FROM posts WHERE id = ? AND read_id = ? AND checkpoint_id IS ? AND ${visible}`, parent, read, checkpoint, c.user, c.user);
    if (parent && !original) throw new HTTPError(404, "The original post is unavailable.");
    const spoiler = Number(Boolean(input.isSpoiler || original?.isSpoiler));
    await c.rateLimit("post", c.user, 30, 60_000);
    const id = crypto.randomUUID();
    const result = await c.run(`INSERT INTO posts
      (id, read_id, checkpoint_id, author_id, parent_id, body, passage, passage_chapter, created_at, is_spoiler)
      SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE ${activeMember}
      AND EXISTS (SELECT 1 FROM reads WHERE id = ? AND closed_at IS NULL)
      AND (? IS NULL OR EXISTS (SELECT 1 FROM posts WHERE id = ? AND ${visible}))`,
      id, read, checkpoint, c.user, parent, body ?? "", passage, chapter, c.now, spoiler, club, c.user, read, parent, parent, c.user, c.user);
    if (!result.meta.changes) throw new HTTPError(409, "The club changed. Refresh and try again.");
    return response({ id }, 201);
  }
  return null;
}

async function changePrompt(c, club, read, thread) {
  await c.requireMembership(club, true);
  await c.requireRead(club, read, true);
  await checkpointFor(c, read, thread);
  if (c.method === "DELETE") {
    await c.run(`DELETE FROM discussion_prompts WHERE read_id = ? AND thread_id = ? AND ${promptOwner}`,
      read, thread, read, club, c.user);
    return response({ ok: true });
  }
  const body = text((await c.body()).body, 1000);
  passFilter(c.env, body);
  const changed = await c.run(`INSERT INTO discussion_prompts (read_id, thread_id, body, updated_at)
    SELECT ?, ?, ?, ? WHERE ${promptOwner}
    ON CONFLICT(read_id, thread_id) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at`,
    read, thread, body, c.now, read, club, c.user);
  if (!changed.meta.changes) throw new HTTPError(409, "The club or its reading changed. Refresh and try again.");
  return response({ ok: true });
}

async function revealPost(c, club, read, id) {
  const [posts, reactions] = await c.batch([
    c.sql(`SELECT ${postFields} ${postAuthors}
      WHERE posts.id = ? AND posts.read_id = ? AND ${visible} AND ${activeMember}`, club, id, read, c.user, c.user, club, c.user),
    c.sql(`SELECT emoji, account_id AS accountID FROM reactions WHERE post_id = ? AND ${reactionsVisible}`, id, c.user, c.user),
  ]);
  const post = posts.results[0];
  if (!post) throw new HTTPError(404, "This post is unavailable.");
  return response(presentedPost(post, reactions.results, c.user, true));
}

export async function discussionRoutes(c) {
  const [root, club, section, read, segment, id, subroute] = c.path;
  if (root !== "clubs" || !club || section !== "reads" || !read || !id) return null;
  if (segment === "threads" && c.path.length === 6) return discussion(c, club, read, id);
  if (segment === "threads" && subroute === "prompt" && c.path.length === 7 && ["PUT", "DELETE"].includes(c.method)) {
    return changePrompt(c, club, read, id);
  }
  if (segment !== "posts" || c.path.length > 7) return null;
  const { ownerID } = await c.requireMembership(club);
  await c.requireRead(club, read);
  if (!subroute && c.method === "GET") return revealPost(c, club, read, id);
  const post = await c.first(`SELECT author_id AS authorID FROM posts WHERE id = ? AND read_id = ? AND ${visible}`, id, read, c.user, c.user);
  if (!post) throw new HTTPError(404, "This post is unavailable.");
  if (!subroute && c.method === "DELETE") {
    if (post.authorID !== c.user && ownerID !== c.user) throw new HTTPError(403, "Only the author or host can remove this post.");
    await c.run(`DELETE FROM posts WHERE id = ? AND read_id = ? AND ${activeMember}
      AND (author_id = ? OR EXISTS (SELECT 1 FROM clubs WHERE id = ? AND owner_id = ?))`, id, read, club, c.user, c.user, club, c.user);
    return response({ ok: true });
  }
  if (subroute === "reaction" && c.method === "PUT") {
    const { emoji, enabled } = await c.body();
    if (!emojis.has(emoji) || typeof enabled !== "boolean") throw new HTTPError(400, "Choose a supported reaction.");
    if (enabled) await c.run(`INSERT OR IGNORE INTO reactions SELECT ?, ?, ? WHERE ${activeMember}`, id, c.user, emoji, club, c.user);
    else await c.run("DELETE FROM reactions WHERE post_id = ? AND account_id = ? AND emoji = ?", id, c.user, emoji);
    return response({ ok: true });
  }
  if (subroute === "report" && c.method === "POST") {
    const reason = text((await c.body()).reason, 400);
    await c.rateLimit("report", c.user, 20, 3_600_000);
    await c.run(`INSERT INTO reports (id, club_id, reporter_id, post_id, reason, created_at)
      SELECT ?, ?, ?, ?, ?, ? WHERE ${activeMember} AND NOT EXISTS
      (SELECT 1 FROM reports WHERE post_id = ? AND reporter_id = ? AND resolved_at IS NULL)`,
      crypto.randomUUID(), club, c.user, id, reason, c.now, club, c.user, id, c.user);
    return response({ ok: true });
  }
  return null;
}
