import { HTTPError, response, text } from "./http.mjs";

export async function hostedManifest(c, read) {
  if (!c.env.CLUB_MEDIA) return null;
  const row = await c.first("SELECT manifest FROM hosted_copies WHERE read_id = ?", read);
  return row ? JSON.parse(row.manifest) : null;
}

export async function hostedCopyRoutes(c) {
  const [root, club, section, read, resource, copyID, files, index] = c.path;
  const media = c.env.CLUB_MEDIA;
  if (!media || root !== "clubs" || !club || section !== "reads" || !read || resource !== "copy") return null;
  const member = await c.requireMembership(club, c.method === "DELETE" || c.method === "POST");
  await c.requireRead(club, read, c.method === "POST");
  if (!copyID && c.method === "GET") {
    const status = media.status(read);
    return response({
      copy: await hostedManifest(c, read), importing: status.importing,
      error: member.ownerID === c.user ? status.error : null,
    });
  }
  if (!copyID && c.method === "POST") {
    const input = await c.body();
    const source = c.env.CATALOGS?.get(text(input.sourceID, 48));
    const publicationID = text(input.publicationID, 64);
    if (!["ebook", "audiobook"].includes(input.format)) throw new HTTPError(400, "Choose an ebook or audiobook.");
    if (!source?.acquire) throw new HTTPError(404, "This catalog does not host copies.");
    const selection = source.acquire(publicationID, input.format);
    media.start(read, club, c.user, selection);
    return response({ importing: true }, 202);
  }
  if (!copyID && c.method === "DELETE") {
    await media.remove(read, club, c.user);
    return response({ ok: true });
  }
  if (copyID && files === "files" && /^\d{1,3}$/u.test(index ?? "") && ["GET", "HEAD"].includes(c.method)) {
    const manifest = await hostedManifest(c, read);
    if (manifest?.id !== copyID || !manifest.files[Number(index)]) throw new HTTPError(404, "This club copy is unavailable.");
    return media.download(manifest, Number(index), c.request);
  }
  return null;
}
