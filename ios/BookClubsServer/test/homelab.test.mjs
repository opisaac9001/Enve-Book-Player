import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { startServer } from "../src/homelab/server.mjs";
import { loadCatalogs } from "../src/homelab/catalogs.mjs";
import { atomFeed } from "../src/homelab/atom.mjs";

const origin = (server) => "http://127.0.0.1:" + server.address().port;
const close = (server) => new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));

function client(server, token) {
  return async (path, method = "GET", body, expected = 200) => {
    const response = await fetch(origin(server) + "/v1/" + path, {
      method,
      headers: { ...(token ? { Authorization: "Bearer " + token } : {}), "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const json = await response.json();
    assert.equal(response.status, expected, method + " " + path + " " + (json.error ?? ""));
    return json;
  };
}

async function signUp(server, name) {
  const credentials = await client(server)("accounts", "POST", { name }, 201);
  return { ...credentials, request: client(server, credentials.token) };
}

async function clubWithRead(host, title) {
  const { id } = await host("clubs", "POST", {
    name: title + " Readers",
    read: { title, checkpoints: [{ label: "Part 1", trackPosition: 0.5 }] },
  }, 201);
  const club = "clubs/" + id;
  const details = await host(club);
  const read = club + "/reads/" + details.reads[0].id;
  const reading = await host(read);
  return { club, read, checkpoint: reading.checkpoints[0].id };
}

test("homelab serves a discoverable protocol, ships web assets, and preserves private notes", async (t) => {
  const data = await mkdtemp(join(tmpdir(), "book-club-home-"));
  const database = join(data, "book-club.sqlite");
  let server = await startServer({ port: 0, database, webOrigins: ["https://reader.example.net"] });
  t.after(async () => {
    if (server.listening) await close(server);
    await rm(data, { recursive: true, force: true });
  });
  const discovery = await client(server)("discovery");
  assert.equal(discovery.protocol, "book-club");
  assert.ok(discovery.features.includes("notes"));
  assert.ok(!discovery.features.includes("catalogs"));
  const home = await fetch(origin(server));
  assert.equal(home.status, 200);
  assert.match(home.headers.get("Content-Security-Policy"), /script-src 'self'/u);
  assert.match(await home.text(), /book club: by Enve/u);
  const spec = await (await fetch(origin(server) + "/openapi.json")).json();
  assert.equal(spec.info.version, discovery.version);
  assert.ok(spec.paths["/clubs/{club}/reads/{read}/notes"].post);
  const preflight = await fetch(origin(server) + "/v1/me/notes", { method: "OPTIONS",
    headers: { Origin: "https://reader.example.net", "Access-Control-Request-Method": "GET", "Access-Control-Request-Headers": "authorization" } });
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get("Access-Control-Allow-Origin"), "https://reader.example.net");
  const unrelatedOrigin = await fetch(origin(server) + "/v1/discovery", { headers: { Origin: "https://unrelated.example.net" } });
  assert.equal(unrelatedOrigin.headers.get("Access-Control-Allow-Origin"), null);

  const [host, guest, outsider] = await Promise.all([
    signUp(server, "Host"), signUp(server, "Guest"), signUp(server, "Outsider"),
  ]);
  const { club, read, checkpoint } = await clubWithRead(host.request, "Persuasion");
  const { code } = await host.request(club + "/invite", "POST");
  await guest.request("clubs/join", "POST", { code, name: "Bookish Guest" });
  const notes = read + "/notes";
  const { id: privateID } = await guest.request(notes, "POST", { body: "Private on creation" }, 201);
  const { id: sharedID } = await guest.request(notes, "POST", { body: "Chapter details", checkpointID: checkpoint, visibility: "club" }, 201);
  await guest.request(notes, "POST", { body: "Bad checkpoint", checkpointID: crypto.randomUUID() }, 404);
  assert.deepEqual((await host.request(notes)).notes, []);
  assert.deepEqual((await outsider.request(notes, "GET", undefined, 404)), { error: "This club is unavailable." });
  const revealed = (await host.request(notes + "?revealSpoilers=true")).notes;
  assert.deepEqual(revealed.map(({ id, authorName }) => [id, authorName]), [[sharedID, "Bookish Guest"]]);
  await host.request(notes + "/" + sharedID, "PATCH", { body: "Unauthorized edit" }, 404);
  await host.request("me/notes/" + sharedID, "DELETE", undefined, 404);
  await host.request(read + "/checkpoints/" + checkpoint + "/complete", "PUT", {});
  assert.deepEqual((await host.request(notes)).notes.map(({ id }) => id), [sharedID]);
  await guest.request(notes + "/" + sharedID, "PATCH", { body: "Revised, only for me", visibility: "private", checkpointID: checkpoint });
  assert.deepEqual((await host.request(notes + "?revealSpoilers=true")).notes, []);
  await guest.request(notes + "/" + sharedID, "PATCH", { body: "Shared with the club", visibility: "club" });
  assert.equal((await host.request(notes)).notes[0].body, "Shared with the club");
  await host.request("blocks/" + guest.account.id, "PUT");
  assert.deepEqual((await host.request(notes)).notes, []);
  await host.request("blocks/" + guest.account.id, "DELETE");

  await close(server);
  server = await startServer({ port: 0, database });
  const restored = await client(server)("sessions", "POST", { recoveryKey: guest.recoveryKey }, 201);
  const guestAgain = client(server, restored.token);
  assert.equal((await guestAgain("me/notes")).notes.length, 2);
  await client(server, host.token)(club, "DELETE");
  const retained = (await guestAgain("me/notes")).notes;
  assert.equal(retained.length, 2);
  assert.ok(retained.every((entry) => entry.readID === null && entry.clubID === null && entry.visibility === "private"));
  assert.ok(retained.every((entry) => entry.bookTitle === "Persuasion"));
  await guestAgain("me/notes/" + privateID, "DELETE");
  assert.equal((await guestAgain("me/notes")).notes.length, 1);
});

const feed = (contents) => '<feed xmlns="http://www.w3.org/2005/Atom">' + contents + "</feed>";
const entry = (title) => '<entry><id>upstream-secret-book-id</id><title>' + title +
  '</title><author><name>Jane Austen</name></author><link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/download/secret"/></entry>';

test("Atom parser handles namespace prefixes and character references, and rejects malformed documents", () => {
  assert.equal(atomFeed('<a:feed xmlns:a="http://www.w3.org/2005/Atom"><a:entry><a:title><![CDATA[B&B]]> &#x26; C</a:title></a:entry></a:feed>')
    .entries[0].title, "B&B & C");
  assert.throws(() => atomFeed("<!DOCTYPE feed>" + feed("")), /XML element/u);
  assert.throws(() => atomFeed(feed("<entry><title>Oops</entry>")), /Mismatched/u);
});

test("prompts, individual spoiler reveals and the cross-club feed honor membership and privacy", async (t) => {
  const server = await startServer({ port: 0, database: ":memory:" });
  t.after(() => close(server));
  const [host, guest, other] = await Promise.all([
    signUp(server, "Host"), signUp(server, "Guest"), signUp(server, "Other"),
  ]);
  const { club, read, checkpoint } = await clubWithRead(host.request, "Persuasion");
  const secretClub = await clubWithRead(other.request, "Another book");
  const { code } = await host.request(club + "/invite", "POST");
  await guest.request("clubs/join", "POST", { code, name: "Chapter Guest" });
  const chapter = read + "/threads/" + checkpoint;
  const general = read + "/threads/general";
  await guest.request(chapter + "/prompt", "PUT", { body: "Unauthorized prompt" }, 403);
  await host.request(read + "/threads/" + crypto.randomUUID() + "/prompt", "PUT", { body: "Wrong checkpoint" }, 404);
  await host.request(chapter + "/prompt", "PUT", { body: "What surprised you?" });
  await host.request(chapter + "/prompt", "PUT", { body: "What changed your mind?" });
  await host.request(general + "/prompt", "PUT", { body: "Introduce yourself." });
  assert.equal((await guest.request(chapter)).prompt.body, "What changed your mind?");
  assert.equal((await guest.request(general)).prompt.body, "Introduce yourself.");
  assert.equal((await guest.request(chapter)).discussionTools, true);
  await guest.request(chapter + "/prompt", "DELETE", undefined, 403);
  await host.request(chapter + "/prompt", "DELETE");
  assert.equal((await guest.request(chapter)).prompt, null);

  await guest.request(general, "POST", { body: "Invalid status", isSpoiler: "true" }, 400);
  const { id } = await guest.request(general, "POST", {
    body: "The surprise ending", passage: "A revealing line", passageChapter: "Final act", isSpoiler: true,
  }, 201);
  const ordinary = await guest.request(general, "POST", { body: "General hello" }, 201);
  const hidden = (await host.request(general)).posts.find((post) => post.id === id);
  assert.deepEqual([hidden.isSpoiler, hidden.concealed, hidden.body, hidden.passage, hidden.passageChapter], [true, true, "", null, null]);
  assert.ok(!(await host.request(general)).posts.find((post) => post.id === ordinary.id).concealed);
  assert.equal((await guest.request(general)).posts.find((post) => post.id === id).body, "The surprise ending");
  const single = read + "/posts/" + id;
  const revealed = await host.request(single);
  assert.equal(revealed.body, "The surprise ending");
  assert.equal(revealed.concealed, false);
  await other.request(single, "GET", undefined, 404);
  const reply = await host.request(general, "POST", { body: "Spoiler reply", parentID: id, isSpoiler: false }, 201);
  assert.equal((await guest.request(general)).posts.find((post) => post.id === reply.id).concealed, true);

  await guest.request(chapter.replace("/threads/", "/checkpoints/") + "/complete", "PUT", {});
  await guest.request(read + "/notes", "POST", { body: "Private thought" }, 201);
  const summaries = await guest.request("clubs");
  assert.deepEqual(summaries.map(({ id, currentReadID }) => [id, currentReadID]),
    [[club.split("/")[1], read.split("/").at(-1)]]);
  const feed = (await host.request("me/feed")).events;
  assert.ok(feed.some((event) => event.id === id && event.kind === "post" && event.memberName === "Chapter Guest"));
  assert.ok(feed.some((event) => event.kind === "checkpoint"));
  assert.ok(feed.every((event) => event.clubID === club.split("/")[1]));
  const feedText = JSON.stringify(feed);
  for (const privateText of ["Another book", "Private thought", "The surprise ending", "A revealing line", "Spoiler reply"]) {
    assert.ok(!feedText.includes(privateText));
  }
  assert.ok((await other.request("me/feed")).events.every((event) => event.clubID === secretClub.club.split("/")[1]));
  for (let index = 0; index < 20; index++) {
    await guest.request(general, "POST", { body: "Guest response " + index }, 201);
    await host.request(general, "POST", { body: "Host response " + index }, 201);
  }
  const recent = await host.request("me/feed");
  assert.equal(recent.events.length, 40);
  assert.ok(recent.before);
  const older = await host.request("me/feed?before=" + encodeURIComponent(recent.before));
  assert.ok(older.events.some((event) => event.kind === "readStarted"));
  const pages = [...recent.events, ...older.events];
  assert.equal(new Set(pages.map((event) => event.id)).size, pages.length);
  assert.equal(older.before, null);
  await host.request("me/feed?before=invalid", "GET", undefined, 400);
  await host.request("blocks/" + guest.account.id, "PUT");
  await host.request(single, "GET", undefined, 404);
  assert.ok((await host.request("me/feed")).events.every((event) => event.memberName !== "Chapter Guest"));
  await host.request("blocks/" + guest.account.id, "DELETE");
  await guest.request(club + "/leave", "POST");
  assert.deepEqual((await guest.request("me/feed")).events, []);
  await host.request(club + "/reads", "POST", { title: "Emma", checkpoints: [] }, 201);
  await host.request(general + "/prompt", "PUT", { body: "Archived" }, 409);
  assert.equal((await host.request(general)).prompt.body, "Introduce yourself.");
});

test("club summaries and discussion links follow the viewer's reading plan and privacy settings", async (t) => {
  const server = await startServer({ port: 0, database: ":memory:" });
  t.after(() => close(server));
  const [host, guest, outsider] = await Promise.all([
    signUp(server, "Club Host"), signUp(server, "Reader"), signUp(server, "Outsider"),
  ]);
  const { club, read, checkpoint } = await clubWithRead(host.request, "Emma");
  const { code } = await host.request(club + "/invite", "POST");
  await guest.request("clubs/join", "POST", { code });
  const dueAt = Date.now() + 86_400_000;
  const nextCheckpoint = await host.request(read + "/checkpoints", "POST", { label: "Part 2", dueAt }, 201);
  const preview = async (member) => (await member.request("clubs"))[0]?.nextCheckpoint;
  assert.deepEqual(await preview(guest), { label: "Part 1", dueAt: null });
  await guest.request(read + "/checkpoints/" + checkpoint + "/complete", "PUT", {});
  assert.deepEqual(await preview(guest), { label: "Part 2", dueAt });
  assert.deepEqual(await preview(host), { label: "Part 1", dueAt: null });
  assert.equal(await preview(outsider), undefined);

  const threadID = nextCheckpoint.id;
  const chapter = read + "/threads/" + threadID;
  const { id: postID } = await host.request(chapter, "POST", { body: "A hidden ending", isSpoiler: true }, 201);
  await guest.request(read + "/posts/" + postID + "/reaction", "PUT", { emoji: "\ud83d\udcda", enabled: true });
  const event = (await guest.request("me/feed")).events.find(({ id }) => id === postID);
  assert.deepEqual(event.discussion, { clubID: club.split("/")[1], readID: read.split("/").at(-1), threadID, postID });
  assert.ok(!JSON.stringify(event).includes("A hidden ending"));
  const focus = chapter + "?focus=" + postID;
  const { focusedPost } = await guest.request(focus);
  assert.deepEqual([focusedPost.id, focusedPost.concealed, focusedPost.body, focusedPost.reactions[0].emoji],
    [postID, true, "", "\ud83d\udcda"]);
  assert.equal((await guest.request(read + "/threads/general?focus=" + postID)).focusedPost, null);
  await outsider.request(focus, "GET", undefined, 404);
  await guest.request(chapter + "?focus=invalid", "GET", undefined, 400);

  for (let i = 0; i < 21; i++) {
    await host.request(chapter, "POST", { body: "Host post " + i }, 201);
    await guest.request(chapter, "POST", { body: "Member post " + i }, 201);
  }
  const olderTarget = await guest.request(focus);
  assert.ok(olderTarget.before);
  assert.ok(!olderTarget.posts.some(({ id }) => id === postID));
  assert.equal(olderTarget.focusedPost.id, postID);
  await guest.request(read + "/checkpoints/" + threadID + "/complete", "PUT", {});
  assert.equal(await preview(guest), null);
  await host.request(club + "/reads", "POST", { title: "Persuasion", checkpoints: [] }, 201);
  const archivedTarget = await guest.request(focus);
  assert.equal(archivedTarget.archived, true);
  assert.equal(archivedTarget.focusedPost.concealed, true);
  await guest.request("blocks/" + host.account.id, "PUT");
  assert.equal((await guest.request(focus)).focusedPost, null);
  await guest.request(club + "/leave", "POST");
  await guest.request(focus, "GET", undefined, 404);
});

test("catalog plugins browse OPDS 1 and 2, Grimmory, Audiobookshelf and an external HTTP adapter", async (t) => {
  const data = await mkdtemp(join(tmpdir(), "book-club-plugins-"));
  const calls = [];
  const upstream = createServer((request, response) => {
    const url = new URL(request.url, "http://provider.invalid");
    calls.push({ path: url.pathname, query: url.searchParams, authorization: request.headers.authorization });
    const xml = (body) => response.writeHead(200, { "Content-Type": "application/atom+xml" }).end(body);
    const json = (body) => response.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify(body));
    const absItem = { id: "private-item-id", mediaType: "book", media: { duration: 500, metadata: { title: "Northanger Abbey", authorName: "Jane Austen" } } };
    switch (url.pathname) {
      case "/opds": return response.writeHead(301, { Location: "/opds/" }).end();
      case "/opds/": return xml(feed('<link rel="search" type="application/opensearchdescription+xml" href="/find"/>' +
        '<entry><title>All books</title><link type="application/atom+xml;profile=opds-catalog" href="/shelf"/></entry>'));
      case "/find": return xml('<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/"><Url type="application/atom+xml" template="/shelf?q={searchTerms}&amp;limit={count}"/></OpenSearchDescription>');
      case "/shelf": return xml(feed((!url.searchParams.has("page") ? '<link rel="next" href="/shelf?page=2"/>' : "") +
        entry(url.searchParams.has("page") ? "Sense &amp; Sensibility" : "Mansfield Park")));
      case "/opds2": return json({ publications: [{ metadata: { identifier: "local-provider-id", title: "Emma", author: { name: "Jane Austen" } },
        links: [{ rel: "http://opds-spec.org/acquisition", href: "/private", type: "application/epub+zip" }] }],
      navigation: [{ title: "Off-site", href: "http://catalog.invalid/feed" }] });
      case "/grimmory/api/v1/opds/catalog": return xml(feed(entry("Persuasion")));
      case "/abs/api/libraries/demo/items": return json({ results: [absItem], total: 51 });
      case "/abs/api/libraries/demo/search": return json({ book: [{ libraryItem: absItem }] });
      case "/external": return json({ publications: [{ id: "provider-id", title: "Pride and Prejudice", author: "Jane Austen", format: "ebook",
        token: "never-return-this-field" }], nextCursor: url.searchParams.has("cursor") ? null : "opaque-from-external" });
      default: return response.writeHead(404).end();
    }
  });
  await new Promise((resolve) => upstream.listen(0, "127.0.0.1", resolve));
  const url = origin(upstream);
  const config = join(data, "catalogs.json");
  await writeFile(config, JSON.stringify([
    { id: "opds", name: "A library", type: "opds", url: url + "/opds" },
    { id: "opds2", name: "Another library", type: "opds", url: url + "/opds2" },
    { id: "grimmory", name: "Grimmory", type: "grimmory", url: url + "/grimmory",
      usernameEnv: "GRIM_USER", passwordEnv: "GRIM_PASS" },
    { id: "abs", name: "Audiobookshelf", type: "audiobookshelf", url: url + "/abs", tokenEnv: "ABS_TOKEN", libraryId: "demo" },
    { id: "external", name: "Another service", type: "book-club", url: url + "/external" },
  ]));
  const catalogs = loadCatalogs(config, { GRIM_USER: "catalog-reader", GRIM_PASS: "fixture", ABS_TOKEN: "fake-provider-token" });
  const server = await startServer({ port: 0, database: ":memory:", catalogs });
  t.after(async () => {
    await Promise.all([close(server), close(upstream)]);
    await rm(data, { recursive: true, force: true });
  });
  const host = await signUp(server, "Catalog host");
  const outsider = await signUp(server, "Outside reader");
  const { club } = await clubWithRead(host.request, "Emma");
  const prefix = club + "/catalog";
  assert.equal((await host.request(prefix)).sources.length, 5);
  await outsider.request(prefix + "/opds", "GET", undefined, 404);
  const { navigation: [shelf] } = await host.request(prefix + "/opds");
  const firstPage = await host.request(prefix + "/opds?cursor=" + shelf.cursor);
  const secondPage = await host.request(prefix + "/opds?cursor=" + firstPage.nextCursor);
  assert.equal(secondPage.publications[0].title, "Sense & Sensibility");
  assert.equal((await host.request(prefix + "/opds?q=Mansfield")).publications[0].title, "Mansfield Park");
  assert.equal(calls.findLast((call) => call.path === "/shelf").query.get("q"), "Mansfield");
  const jsonPage = await host.request(prefix + "/opds2");
  assert.deepEqual(jsonPage.navigation, []);
  assert.equal(jsonPage.publications[0].title, "Emma");
  assert.equal((await host.request(prefix + "/grimmory?q=Persuasion")).publications[0].format, "ebook");
  const grim = calls.find((call) => call.path.startsWith("/grimmory"));
  assert.ok(grim.authorization.startsWith("Basic "));
  assert.equal(grim.query.get("q"), "Persuasion");
  assert.equal((await host.request(prefix + "/abs?q=Northanger")).publications[0].format, "audiobook");
  const abs = await host.request(prefix + "/abs");
  assert.notEqual(abs.publications[0].id, "private-item-id");
  assert.ok(abs.nextCursor);
  assert.ok(calls.some((call) => call.path.endsWith("/search") && call.authorization === "Bearer fake-provider-token"));
  const external = await host.request(prefix + "/external");
  assert.equal(external.publications[0].title, "Pride and Prejudice");
  assert.equal(external.publications[0].token, undefined);
  assert.notEqual(external.nextCursor, "opaque-from-external");
  assert.equal((await host.request(prefix + "/external?cursor=" + external.nextCursor)).nextCursor, null);
  await host.request(prefix + "/opds?cursor=" + external.nextCursor, "GET", undefined, 400);
});

test("hosted editions survive restart, with ordered files, member access and safe replacement", async (t) => {
  const temp = await mkdtemp(join(tmpdir(), "club-hosted-book-"));
  const database = join(temp, "books.sqlite");
  const data = Buffer.from("An ebook file for the club.");
  let rejected = false;
  const upstream = createServer((request, response) => {
    const url = new URL(request.url, "http://provider.invalid");
    const send = (type, contents) => response.writeHead(200, { "Content-Type": type }).end(contents);
    switch (url.pathname) {
      case "/opds":
        return send("application/atom+xml", feed(entry("Persuasion")));
      case "/readonly":
        return send("application/atom+xml", feed(entry("Persuasion")));
      case "/download/secret":
        return send("application/epub+zip", data);
      case "/grim/api/v1/opds/catalog":
        assert.match(request.headers.authorization, /^Basic /u);
        return send("application/atom+xml", feed(entry("Emma").replace('href="/download/secret"', 'href="/grim/download"')));
      case "/grim/download":
        if (rejected) return response.writeHead(403).end();
        return send("application/epub+zip", "A different ebook edition.");
      case "/abs/api/libraries/demo/items":
        assert.equal(request.headers.authorization, "Bearer fixture-secret");
        return send("application/json", JSON.stringify({ total: 1, results: [{ id: "book-a", mediaType: "book",
          media: { numTracks: 2, metadata: { title: "Northanger Abbey" } } }] }));
      case "/abs/api/items/book-a":
        assert.equal(url.searchParams.get("expanded"), "1");
        return send("application/json", JSON.stringify({ mediaType: "book", libraryId: "demo", media: { audioFiles: [
          { index: 2, ino: "303", metadata: { filename: "Part 2.mp3" } },
          { index: 1, ino: "202", metadata: { filename: "Part 1.mp3" } },
          { index: 0, ino: "101", metadata: { filename: "Excluded.mp3" }, exclude: true },
        ] } }));
      case "/abs/api/items/book-a/file/202/download":
        return send("audio/mpeg", "first track");
      case "/abs/api/items/book-a/file/303/download":
        return send("audio/mpeg", "second track");
      default: return response.writeHead(404).end();
    }
  });
  await new Promise((resolve) => upstream.listen(0, "127.0.0.1", resolve));
  const url = origin(upstream);
  const config = join(temp, "catalogs.json");
  await writeFile(config, JSON.stringify([
    { id: "opds", name: "Shareable catalog", type: "opds", url: url + "/opds", shareFiles: true },
    { id: "readonly", name: "Metadata catalog", type: "opds", url: url + "/readonly" },
    { id: "grimmory", name: "Grimmory", type: "grimmory", url: url + "/grim", shareFiles: true, usernameEnv: "FIXTURE_USER", passwordEnv: "FIXTURE_PASSWORD" },
    { id: "abs", name: "Audiobookshelf", type: "audiobookshelf", url: url + "/abs", shareFiles: true, libraryId: "demo", tokenEnv: "FIXTURE_TOKEN" },
  ]));
  const catalogs = loadCatalogs(config, { FIXTURE_USER: "test", FIXTURE_PASSWORD: "fixture", FIXTURE_TOKEN: "fixture-secret" });
  let server = await startServer({ port: 0, database, catalogs });
  t.after(async () => {
    if (server.listening) await close(server);
    if (upstream.listening) await close(upstream);
    await rm(temp, { recursive: true, force: true });
  });
  const host = await signUp(server, "Host");
  const friend = await signUp(server, "Member");
  const outsider = await signUp(server, "Outsider");
  const { club, read } = await clubWithRead(host.request, "Persuasion");
  const { code } = await host.request(club + "/invite", "POST");
  await friend.request("clubs/join", "POST", { code });

  const selected = async (sourceID, format = "ebook") => {
    const { publications: [item] } = await host.request(club + "/catalog/" + sourceID);
    if (sourceID !== "readonly") assert.ok(item.shareableFormats.includes(format));
    assert.equal(item.url, undefined);
    return { sourceID, publicationID: item.id, format };
  };
  const finished = async (path) => {
    for (let attempt = 0; attempt < 100; attempt++) {
      const status = await host.request(path);
      if (!status.importing) return status;
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.fail("The import did not finish.");
  };

  const copyPath = read + "/copy";
  const opds = await selected("opds");
  await host.request(copyPath, "POST", await selected("readonly"), 404);
  await friend.request(copyPath, "POST", opds, 403);
  await host.request(copyPath, "POST", opds, 202);
  const { copy, error } = await finished(copyPath);
  assert.equal(error, null);
  assert.equal(copy.files[0].name, "Persuasion.epub");
  assert.equal((await friend.request(read)).hostedCopy.id, copy.id);
  const filePath = "/v1/" + copyPath + "/" + copy.id + "/files/0";
  const fileURL = origin(server) + filePath;
  const authorized = { Authorization: "Bearer " + friend.token };
  assert.equal((await fetch(fileURL)).status, 401);
  assert.equal((await fetch(fileURL, { headers: { Authorization: "Bearer " + outsider.token } })).status, 404);
  const ranged = await fetch(fileURL, { headers: { ...authorized, Range: "bytes=3-6" } });
  assert.equal(ranged.status, 206);
  assert.equal(ranged.headers.get("Content-Range"), "bytes 3-6/" + data.length);
  assert.deepEqual(Buffer.from(await ranged.arrayBuffer()), data.subarray(3, 7));
  assert.equal((await fetch(fileURL, { headers: { ...authorized, Range: "bytes=1000-" } })).status, 416);
  assert.equal((await fetch(fileURL, { headers: authorized, method: "HEAD" })).headers.get("Content-Length"), String(data.length));
  const form = await fetch(fileURL, { method: "POST", body: new URLSearchParams({ session: friend.token }) });
  assert.equal(form.status, 200);
  assert.deepEqual(Buffer.from(await form.arrayBuffer()), data);
  await friend.request(copyPath, "DELETE", undefined, 403);

  rejected = true;
  const grimmory = await selected("grimmory");
  await host.request(copyPath, "POST", grimmory, 202);
  const failure = await finished(copyPath);
  assert.ok(failure.error);
  assert.equal(failure.copy.id, copy.id);
  rejected = false;
  await host.request(copyPath, "POST", grimmory, 202);
  assert.equal((await finished(copyPath)).copy.title, "Emma");
  assert.equal((await fetch(fileURL, { headers: authorized })).status, 404);

  await host.request(copyPath, "POST", await selected("abs", "audiobook"), 202);
  const audio = (await finished(copyPath)).copy;
  assert.deepEqual(audio.files.map(({ name }) => name), ["001 - Northanger Abbey.mp3", "002 - Northanger Abbey.mp3"]);
  const tracks = audio.files.map(({ index }) => "/v1/" + copyPath + "/" + audio.id + "/files/" + index);
  await close(server);
  await close(upstream);
  server = await startServer({ port: 0, database });
  const cachedOrigin = origin(server);
  assert.equal(await (await fetch(cachedOrigin + tracks[0], { headers: authorized })).text(), "first track");
  assert.equal(await (await fetch(cachedOrigin + tracks[1], { headers: authorized })).text(), "second track");
  await client(server, host.token)(copyPath, "DELETE");
  assert.equal((await fetch(cachedOrigin + tracks[0], { headers: authorized })).status, 404);
  assert.equal((await client(server, friend.token)(read)).hostedCopy, null);
});
