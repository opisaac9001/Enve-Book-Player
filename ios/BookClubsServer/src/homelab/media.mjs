import { randomUUID } from "node:crypto";
import { createWriteStream, mkdirSync } from "node:fs";
import { mkdir, open, readdir, rm, statfs } from "node:fs/promises";
import { join } from "node:path";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { HTTPError } from "../http.mjs";

const hostRead = `EXISTS (SELECT 1 FROM reads JOIN clubs ON reads.club_id = clubs.id
  WHERE reads.id = ? AND clubs.id = ? AND clubs.owner_id = ?`;
const copyDirectory = /^copy-([a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12})$/u;

function fileName(value, extension, index, count) {
  const clean = [...value.replace(/[^\p{L}\p{M}\p{N} .()_'-]/gu, " ")].slice(0, 55).join("").trim().replace(/^[. ]+|[. ]+$/gu, "");
  const prefix = count > 1 ? String(index + 1).padStart(3, "0") + " - " : "";
  return prefix + (clean || "Club book") + "." + extension;
}

function byteRange(header, length) {
  const match = /^bytes=(\d{0,16})-(\d{0,16})$/u.exec(header);
  if (!match || (!match[1] && !match[2])) return null;
  const start = match[1] ? Number(match[1]) : Math.max(0, length - Number(match[2]));
  const end = match[1] && match[2] ? Math.min(length - 1, Number(match[2])) : length - 1;
  return Number.isSafeInteger(start) && Number.isSafeInteger(end) && start >= 0 && end >= start && start < length ? { start, end } : null;
}

export function createMediaStore(DB, root, maxBytes) {
  mkdirSync(root, { recursive: true, mode: 0o700 });
  const errors = new Map();
  let job;
  let sweep;
  const run = (sql, ...args) => DB.prepare(sql).bind(...args);
  const directoryFor = (id) => join(root, "copy-" + id);

  async function collect() {
    if (sweep) return sweep;
    sweep = (async () => {
      const entries = await readdir(root, { withFileTypes: true });
      const live = new Set(run("SELECT id FROM hosted_copies").all().results.map(({ id }) => id));
      if (job) live.add(job.id);
      for (const entry of entries) {
        const id = copyDirectory.exec(entry.name)?.[1];
        if (entry.isDirectory() && id && !live.has(id)) {
          await rm(directoryFor(id), { recursive: true, force: true });
        }
      }
    })();
    try { await sweep; }
    finally { sweep = undefined; }
  }

  async function capture(current, club, owner, selection) {
    const directory = directoryFor(current.id);
    let saved = false;
    try {
      const signal = AbortSignal.any([current.controller.signal, AbortSignal.timeout(3_600_000)]);
      const sources = await selection.files(signal);
      if (!sources.length || sources.length > 250) throw new HTTPError(422, "This edition has no supported files, or has more than 250 tracks.");
      const space = await statfs(root);
      const available = Math.min(maxBytes, space.bavail * space.bsize - 67_108_864);
      if (available <= 0) throw new HTTPError(507, "There is too little free storage for a club copy.");
      await mkdir(directory, { mode: 0o700 });
      const files = [];
      let total = 0;
      for (const [index, source] of sources.entries()) {
        const response = await source.open(signal);
        const length = Number(response.headers.get("Content-Length"));
        if (length && total + length > available) {
          await response.body.cancel();
          throw new HTTPError(413, "This copy exceeds the server’s available space or copy limit.");
        }
        let bytes = 0;
        await pipeline(Readable.fromWeb(response.body), new Transform({
          transform(chunk, _, callback) {
            total += chunk.length;
            bytes += chunk.length;
            if (total > available) callback(new HTTPError(413, "This copy exceeds the server’s available space or copy limit."));
            else callback(null, chunk);
          },
        }), createWriteStream(join(directory, String(index)), { flags: "wx", mode: 0o600 }), { signal });
        if (!bytes || (length && length !== bytes)) throw new HTTPError(502, "The provider returned an incomplete file.");
        files.push({ index, name: fileName(source.name || selection.title, source.extension, index, sources.length),
          bytes, contentType: source.contentType });
      }
      const manifest = { id: current.id, title: selection.title, format: selection.format, files };
      const result = run(`INSERT INTO hosted_copies (read_id, id, manifest)
        SELECT ?, ?, ? WHERE ${hostRead} AND reads.closed_at IS NULL)
        ON CONFLICT(read_id) DO UPDATE SET id = excluded.id, manifest = excluded.manifest`,
      current.read, current.id, JSON.stringify(manifest), current.read, club, owner).run();
      saved = result.meta.changes > 0;
      if (!saved) throw new HTTPError(409, "This reading or its host changed during import.");
    } catch (error) {
      if (!current.controller.signal.aborted) {
        while (errors.size >= 128) errors.delete(errors.keys().next().value);
        errors.set(current.read, error instanceof HTTPError ? error.message : "The club copy import failed. Check the source and try again.");
      }
    } finally {
      if (!saved) await rm(directory, { recursive: true, force: true }).catch(() => {});
      job = undefined;
      await collect().catch(() => {});
    }
  }

  return {
    collect,
    status: (read) => ({ importing: job?.read === read, error: errors.get(read) ?? null }),
    start(read, club, owner, selection) {
      if (job) throw new HTTPError(409, "A club copy is already importing. Try again when it finishes.");
      errors.delete(read);
      job = { read, id: randomUUID(), controller: new AbortController() };
      job.finished = capture(job, club, owner, selection);
    },
    async remove(read, club, owner) {
      const allowed = run("SELECT 1 WHERE " + hostRead + ")", read, club, owner).first();
      if (!allowed) throw new HTTPError(403, "Only the host can do that.");
      if (job?.read === read) job.controller.abort();
      errors.delete(read);
      run("DELETE FROM hosted_copies WHERE read_id = ? AND " + hostRead + ")", read, read, club, owner).run();
      await collect().catch(() => {});
    },
    async close() {
      if (job) {
        job.controller.abort();
        await job.finished;
      }
      await sweep;
    },
    async download(manifest, index, request) {
      const file = manifest.files[index];
      const range = request.headers.get("Range");
      const requested = range && byteRange(range, file.bytes);
      const headers = {
        "Content-Type": file.contentType, "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff",
        "Content-Disposition": "attachment; filename=\"" + file.name.replace(/[^A-Za-z0-9 ._()-]/gu, "_") +
          "\"; filename*=UTF-8''" + encodeURIComponent(file.name).replace(/['()]/gu, (char) => "%" + char.charCodeAt(0).toString(16)),
        "Accept-Ranges": "bytes",
      };
      if (range && !requested) return new Response(null, { status: 416, headers: { ...headers, "Content-Range": "bytes */" + file.bytes } });
      const { start, end } = requested || { start: 0, end: file.bytes - 1 };
      headers["Content-Length"] = String(end - start + 1);
      if (requested) headers["Content-Range"] = "bytes " + start + "-" + end + "/" + file.bytes;
      const handle = await open(join(directoryFor(manifest.id), String(index)), "r")
        .catch(() => { throw new HTTPError(404, "This club file is unavailable."); });
      if (request.method === "HEAD") await handle.close();
      const body = request.method === "HEAD" ? null : Readable.toWeb(handle.createReadStream({ start, end }));
      return new Response(body, { status: requested ? 206 : 200, headers });
    },
  };
}
