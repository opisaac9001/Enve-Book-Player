import { code, hash, HTTPError, json, normalizeCode, passFilter, response, text } from "./http.mjs";
import { clubRoutes } from "./clubs.mjs";
import { discussionRoutes } from "./discussion.mjs";
import { pollRoutes } from "./polls.mjs";
import { noteRoutes } from "./notes.mjs";
import { catalogRoutes } from "./catalog.mjs";
import { hostedCopyRoutes } from "./hosted-copies.mjs";
import { feedRoutes } from "./feed.mjs";

const day = 86_400_000;

class ClubRequest {
  constructor(request, env, url, path) {
    this.request = request;
    this.env = env;
    this.url = url;
    this.path = path;
    this.method = request.method;
    this.now = Date.now();
  }

  sql(query, ...args) { return this.env.DB.prepare(query).bind(...args); }
  first(query, ...args) { return this.sql(query, ...args).first(); }
  run(query, ...args) { return this.sql(query, ...args).run(); }
  batch(statements) { return this.env.DB.batch(statements); }
  async all(query, ...args) { return (await this.sql(query, ...args).all()).results; }
  body() { return json(this.request); }

  async rateLimit(group, subject, allowed, interval) {
    const window = Math.floor(this.now / interval);
    const row = await this.first(`INSERT INTO request_limits VALUES (?, 1, ?)
      ON CONFLICT(key) DO UPDATE SET count = count + 1 RETURNING count`,
    `${group}:${subject}:${window}`, (window + 1) * interval);
    if (row.count > allowed) throw new HTTPError(429, "Too many requests. Try again later.");
  }

  async authenticate() {
    const authorization = this.request.headers.get("Authorization") ?? "";
    const match = /^Bearer ([A-HJ-NP-Z2-9]{52})$/u.exec(authorization);
    if (!match) throw new HTTPError(401, "Sign in to Clubs.");
    this.tokenHash = await hash(match[1]);
    const account = await this.first(`SELECT accounts.id, accounts.name FROM sessions
      JOIN accounts ON accounts.id = sessions.account_id WHERE token_hash = ? AND expires_at > ?`, this.tokenHash, this.now);
    if (!account) throw new HTTPError(401, "Your Clubs session ended. Use your recovery key to sign back in.");
    this.account = account;
    this.user = account.id;
  }

  async requireMembership(club, ownerOnly = false) {
    const membership = await this.first(`SELECT clubs.owner_id AS ownerID, clubs.name FROM memberships
      JOIN clubs ON clubs.id = memberships.club_id
      WHERE club_id = ? AND account_id = ? AND state = 'active'`, club, this.user);
    if (!membership) throw new HTTPError(404, "This club is unavailable.");
    if (ownerOnly && membership.ownerID !== this.user) throw new HTTPError(403, "Only the host can do that.");
    return membership;
  }

  async requireRead(club, read, active = false) {
    const row = await this.first("SELECT closed_at AS closedAt FROM reads WHERE id = ? AND club_id = ?", read, club);
    if (!row) throw new HTTPError(404, "This club read is unavailable.");
    if (active && row.closedAt !== null) throw new HTTPError(409, "This read has been archived.");
    return row;
  }

  activity(club, kind, label) {
    return this.sql("INSERT INTO activity (id, club_id, account_id, kind, label, created_at) VALUES (?, ?, ?, ?, ?, ?)",
      crypto.randomUUID(), club, this.user, kind, label, this.now);
  }

  async newSession(accountID) {
    const token = code(52);
    return { token, statement: this.sql("INSERT INTO sessions VALUES (?, ?, ?)", await hash(token), accountID, this.now + 180 * day) };
  }
}

async function accounts(c) {
  if (c.method === "POST" && ["accounts", "sessions"].includes(c.path[0]) && c.path.length === 1) {
    const ip = c.request.headers.get("CF-Connecting-IP") ?? "local";
    await c.rateLimit(c.path[0], await hash(ip), 40, 3_600_000);
    const input = await c.body();
    if (c.path[0] === "accounts") {
      const name = text(input.name, 36);
      passFilter(c.env, name);
      const id = crypto.randomUUID();
      const recoveryKey = code(32);
      const session = await c.newSession(id);
      await c.batch([
        c.sql("INSERT INTO accounts VALUES (?, ?, ?)", id, name, await hash(recoveryKey)),
        session.statement,
      ]);
      return response({ account: { id, name }, token: session.token, recoveryKey }, 201);
    }
    const account = await c.first("SELECT id, name FROM accounts WHERE recovery_hash = ?", await hash(normalizeCode(input.recoveryKey, 32)));
    if (!account) throw new HTTPError(401, "That recovery key wasn’t found.");
    const session = await c.newSession(account.id);
    await session.statement.run();
    return response({ account, token: session.token, recoveryKey: normalizeCode(input.recoveryKey, 32) }, 201);
  }
  await c.authenticate();
  if (c.path.join("/") === "me" && c.method === "GET") return response(c.account);
  if (c.path.join("/") === "me" && c.method === "DELETE") {
    await c.batch([
      c.sql(`UPDATE clubs SET owner_id = (SELECT account_id FROM memberships
        WHERE club_id = clubs.id AND state = 'active' AND account_id <> ? ORDER BY joined_at, account_id LIMIT 1)
        WHERE owner_id = ? AND EXISTS (SELECT 1 FROM memberships WHERE club_id = clubs.id AND state = 'active' AND account_id <> ?)`,
      c.user, c.user, c.user),
      c.sql("DELETE FROM clubs WHERE owner_id = ?", c.user),
      c.sql("DELETE FROM activity WHERE account_id = ?", c.user),
      c.sql("DELETE FROM nominations WHERE account_id = ? AND id NOT IN (SELECT nomination_id FROM poll_options)", c.user),
      c.sql("DELETE FROM accounts WHERE id = ?", c.user),
    ]);
    return response({ ok: true });
  }
  if (c.path.join("/") === "me/session" && c.method === "DELETE") {
    await c.run("DELETE FROM sessions WHERE token_hash = ?", c.tokenHash);
    return response({ ok: true });
  }
  if (c.path.join("/") === "me/recovery" && c.method === "POST") {
    const key = code(32);
    await c.batch([
      c.sql("UPDATE accounts SET recovery_hash = ? WHERE id = ?", await hash(key), c.user),
      c.sql("DELETE FROM sessions WHERE account_id = ? AND token_hash <> ?", c.user, c.tokenHash),
    ]);
    return response({ recoveryKey: key });
  }
  return null;
}

async function moderation(c) {
  const secret = c.env.CLUB_MODERATOR_TOKEN;
  const supplied = c.request.headers.get("Authorization") ?? "";
  if (!secret || await hash(supplied) !== await hash(`Bearer ${secret}`)) throw new HTTPError(404, "Not found.");
  if (c.method === "GET" && c.path.length === 1) {
    return response(await c.all(`SELECT reports.id, reports.club_id AS clubID, posts.body, posts.passage, reports.reason,
      reports.created_at AS createdAt FROM reports LEFT JOIN posts ON posts.id = reports.post_id
      WHERE resolved_at IS NULL ORDER BY reports.created_at LIMIT 100`));
  }
  if (c.method === "POST" && c.path.length === 2) {
    const input = await c.body();
    if (typeof input.removePost !== "boolean") throw new HTTPError(400, "Choose a resolution.");
    await c.batch([
      c.sql("DELETE FROM posts WHERE ? AND id = (SELECT post_id FROM reports WHERE id = ? AND resolved_at IS NULL)", Number(input.removePost), c.path[1]),
      c.sql("UPDATE reports SET resolved_at = ? WHERE id = ? AND resolved_at IS NULL", c.now, c.path[1]),
    ]);
    return response({ ok: true });
  }
  throw new HTTPError(404, "Not found.");
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    if (parts.shift() !== "v1" || parts.length > 8) return response({ error: "Not found." }, 404);
    const c = new ClubRequest(request, env, url, parts);
    try {
      if (c.method === "GET" && parts.join("/") === "health") return response({ ok: true });
      if (c.method === "GET" && parts.join("/") === "discovery") {
        return response({ name: "book club: by Enve", protocol: "book-club", version: "1.0-draft",
          api: "/v1", features: ["clubs", "club-feed", "reading-plans", "progress", "discussions", "discussion-prompts", "post-spoilers", "votes", "notes",
            ...(env.CATALOGS?.size ? ["catalogs"] : []), ...(env.CLUB_MEDIA ? ["hosted-copies"] : [])] });
      }
      if (parts[0] === "moderation") return await moderation(c);
      const accountResponse = await accounts(c);
      if (accountResponse) return accountResponse;
      if (!["GET", "HEAD"].includes(c.method)) await c.rateLimit("write", c.user, 240, 60_000);
      return await feedRoutes(c) ?? await hostedCopyRoutes(c) ?? await catalogRoutes(c) ?? await noteRoutes(c) ??
        await clubRoutes(c) ?? await discussionRoutes(c) ??
        await pollRoutes(c) ?? response({ error: "Not found." }, 404);
    } catch (error) {
      if (error instanceof HTTPError) return response({ error: error.message }, error.status);
      console.error("Club request failed", c.method, parts[0] ?? "unknown", error.name);
      return response({ error: "Clubs is temporarily unavailable. Try again." }, 500);
    }
  },

  async scheduled(event, env) {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM request_limits WHERE expires_at <= ?").bind(event.scheduledTime),
      env.DB.prepare("DELETE FROM sessions WHERE expires_at <= ?").bind(event.scheduledTime),
      env.DB.prepare("DELETE FROM invites WHERE expires_at <= ?").bind(event.scheduledTime),
    ]);
  },
};
