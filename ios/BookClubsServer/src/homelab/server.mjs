import { createServer } from "node:http";
import { mkdirSync, readFileSync } from "node:fs";
import { dirname } from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { fileURLToPath } from "node:url";
import worker from "../worker.mjs";
import { openDatabase } from "./sqlite.mjs";
import { loadCatalogs } from "./catalogs.mjs";
import { createMediaStore } from "./media.mjs";

const fileDownloadPath = /^\/v1\/clubs\/[^/]+\/reads\/[^/]+\/copy\/[^/]+\/files\/\d{1,3}$/u;

async function formSession(incoming) {
  let bytes = 0;
  const chunks = [];
  for await (const chunk of incoming) {
    bytes += chunk.length;
    if (bytes > 160) return null;
    chunks.push(chunk);
  }
  const fields = new URLSearchParams(Buffer.concat(chunks).toString("utf8"));
  const token = fields.size === 1 && fields.get("session");
  return /^[A-HJ-NP-Z2-9]{52}$/u.test(token || "") ? token : null;
}

const assets = new Map([
  ["/", ["../../public/index.html", "text/html; charset=utf-8"]],
  ["/styles.css", ["../../public/styles.css", "text/css; charset=utf-8"]],
  ["/app.mjs", ["../../public/app.mjs", "text/javascript; charset=utf-8"]],
  ["/openapi.json", ["../../protocol/openapi.json", "application/json; charset=utf-8"]],
]);

const responseHeaders = {
  "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
};

export async function startServer({
  host = "127.0.0.1", port = 8794, database = "./data/book-club.sqlite", catalogConfig,
  moderatorToken, blockedWords, catalogs = loadCatalogs(catalogConfig), webOrigins = [],
  mediaDirectory = database === ":memory:" ? null : database + ".hosted-books",
  maxCopyBytes = 4_294_967_296,
} = {}) {
  if (!Number.isSafeInteger(maxCopyBytes) || maxCopyBytes < 1) throw new Error("Set BOOK_CLUB_COPY_MAX_BYTES to a positive integer.");
  const allowedOrigins = new Set(webOrigins.map((value) => {
    const url = new URL(value);
    if (!["https:", "http:"].includes(url.protocol) || url.origin !== value) {
      throw new Error("Set each allowed web origin to an HTTP(S) origin without a path or trailing slash.");
    }
    return value;
  }));
  mkdirSync(dirname(database), { recursive: true, mode: 0o700 });
  const DB = openDatabase(database);
  let media;
  try { if (mediaDirectory) media = createMediaStore(DB, mediaDirectory, maxCopyBytes); }
  catch (error) { DB.close(); throw error; }
  const env = { DB, CATALOGS: catalogs, CLUB_MEDIA: media, CLUB_MODERATOR_TOKEN: moderatorToken, CLUB_BLOCKED_WORDS: blockedWords };
  const cleanup = async () => {
    try {
      await worker.scheduled({ scheduledTime: Date.now() }, env);
      await media?.collect();
    } catch {
      console.error("Book Club could not clean up expired records.");
    }
  };
  await cleanup();
  const timer = setInterval(cleanup, 900_000).unref();
  const server = createServer({ requestTimeout: 15_000, headersTimeout: 10_000 }, async (incoming, outgoing) => {
    for (const [name, value] of Object.entries(responseHeaders)) outgoing.setHeader(name, value);
    try {
      const target = new URL(incoming.url, "http://book-club.invalid");
      if (!incoming.url.startsWith("/") || target.host !== "book-club.invalid") {
        outgoing.writeHead(400).end();
        return;
      }
      let method = incoming.method;
      if (!target.pathname.startsWith("/v1/")) {
        const asset = assets.get(target.pathname);
        if (!asset || !["GET", "HEAD"].includes(method)) {
          outgoing.writeHead(404).end();
          return;
        }
        const contents = readFileSync(new URL(asset[0], import.meta.url));
        outgoing.writeHead(200, { "Content-Type": asset[1], "Cache-Control": "no-cache", "Content-Length": contents.length });
        outgoing.end(method === "HEAD" ? undefined : contents);
        return;
      }
      const headers = new Headers(incoming.headers);
      const origin = headers.get("Origin");
      if (allowedOrigins.size) outgoing.setHeader("Vary", "Origin");
      if (allowedOrigins.has(origin)) {
        outgoing.setHeader("Access-Control-Allow-Origin", origin);
        outgoing.setHeader("Access-Control-Expose-Headers", "Accept-Ranges, Content-Disposition, Content-Range");
        if (method === "OPTIONS") {
          outgoing.writeHead(204, {
            "Access-Control-Allow-Methods": "GET, HEAD, POST, PUT, PATCH, DELETE",
            "Access-Control-Allow-Headers": "Authorization, Content-Type, Range",
            "Access-Control-Max-Age": "600",
          }).end();
          return;
        }
      }
      if (method === "POST" && fileDownloadPath.test(target.pathname)) {
        const formType = headers.get("Content-Type")?.split(";")[0] === "application/x-www-form-urlencoded";
        const sameSite = !["cross-site", "same-site"].includes(headers.get("Sec-Fetch-Site"));
        const token = formType && sameSite && await formSession(incoming);
        if (!token) {
          outgoing.writeHead(401, { "Content-Type": "application/json", "Cache-Control": "no-store" });
          outgoing.end('{"error":"Sign in to download this club copy."}');
          return;
        }
        headers.set("Authorization", "Bearer " + token);
        headers.delete("Content-Length");
        headers.delete("Content-Type");
        method = "GET";
      }
      headers.set("CF-Connecting-IP", incoming.socket.remoteAddress ?? "local");
      const request = new Request(target, {
        method, headers,
        ...(!["GET", "HEAD"].includes(method) ? { body: Readable.toWeb(incoming), duplex: "half" } : {}),
      });
      const result = await worker.fetch(request, env);
      for (const [name, value] of result.headers) outgoing.setHeader(name, value);
      outgoing.writeHead(result.status);
      if (method === "HEAD" || !result.body) outgoing.end();
      else await pipeline(Readable.fromWeb(result.body), outgoing);
    } catch {
      if (!outgoing.headersSent) {
        outgoing.writeHead(500, { "Content-Type": "application/json", "Cache-Control": "no-store" });
        outgoing.end('{"error":"Book Club is temporarily unavailable."}');
      } else {
        outgoing.destroy();
      }
    }
  });
  server.once("close", () => {
    clearInterval(timer);
    if (media) media.close().catch(() => {}).finally(() => DB.close());
    else DB.close();
  });
  return new Promise((resolve, reject) => {
    const failed = (error) => {
      clearInterval(timer);
      DB.close();
      reject(error);
    };
    server.once("error", failed);
    server.listen(port, host, () => {
      server.off("error", failed);
      resolve(server);
    });
  });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.umask(0o077);
  const port = Number(process.env.BOOK_CLUB_PORT ?? 8794);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Set BOOK_CLUB_PORT to a valid TCP port.");
  const server = await startServer({
    host: process.env.BOOK_CLUB_HOST,
    port,
    database: process.env.BOOK_CLUB_DATABASE,
    catalogConfig: process.env.BOOK_CLUB_CATALOG_CONFIG,
    moderatorToken: process.env.CLUB_MODERATOR_TOKEN,
    blockedWords: process.env.CLUB_BLOCKED_WORDS,
    webOrigins: (process.env.BOOK_CLUB_WEB_ORIGINS ?? "").split(",").map((origin) => origin.trim()).filter(Boolean),
    mediaDirectory: process.env.BOOK_CLUB_MEDIA_DIRECTORY,
    maxCopyBytes: Number(process.env.BOOK_CLUB_COPY_MAX_BYTES ?? 4_294_967_296),
  });
  for (const signal of ["SIGINT", "SIGTERM"]) process.once(signal, () => server.close());
  console.log(`book club: by Enve is listening on port ${server.address().port}.`);
}
