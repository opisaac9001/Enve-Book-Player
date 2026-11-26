import assert from "node:assert/strict";
import test from "node:test";

const service = process.env.ENVE_CLUBS_TEST_URL ?? "http://127.0.0.1:8794";
if (!/^http:\/\/(?:127\.0\.0\.1|localhost):\d+$/u.test(service)) throw new Error("Use the local Clubs worker.");

async function request(path, { method = "GET", body, token, status = 200 } = {}) {
  const response = await fetch(`${service}/v1/${path}`, {
    method,
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: typeof body === "undefined" ? undefined : JSON.stringify(body),
  });
  const data = await response.json();
  assert.equal(response.status, status, `${method} ${path} ${data.error ?? ""}`);
  return data;
}

function createAccount(name) { return request("accounts", { method: "POST", body: { name }, status: 201 }); }

function client(token) {
  return (path, method = "GET", body, status = 200) => request(path, { token, method, body, status });
}

function reading(title, author = null) {
  return { title, author, checkpoints: [{ label: "Chapter 3", chapterKey: "chapter 3", trackPosition: 0.4 },
    { label: "Finish the book", trackPosition: 1, dueAt: Date.now() + 86400000 }] };
}

test("members can read, discuss, vote, and start another book privately", async (t) => {
  const [alice, ben, clara] = await Promise.all([createAccount("Alice"), createAccount("Ben"), createAccount("Clara")]);
  const a = client(alice.token), b = client(ben.token), outside = client(clara.token);
  t.after(async () => { await Promise.allSettled([a("me", "DELETE"), b("me", "DELETE"), outside("me", "DELETE")]); });
  const { id: clubID } = await a("clubs", "POST", { name: "Evening readers", read: reading("Hyperion", "Dan Simmons") }, 201);
  const club = `clubs/${clubID}`;
  assert.equal((await a("clubs"))[0].id, clubID);
  assert.deepEqual(await outside("clubs"), []);
  const { reads: [first] } = await a(club);
  const read = `${club}/reads/${first.id}`;
  const { checkpoints: [chapter, finish] } = await a(read);

  await outside(club, "GET", undefined, 404);
  await outside(read, "GET", undefined, 404);
  const old = await a(`${club}/invite`, "POST");
  const invite = await a(`${club}/invite`, "POST");
  await b("clubs/join", "POST", { code: old.code }, 404);
  await b("clubs/join", "POST", { code: invite.code, name: "   " }, 400);
  await b("clubs/join", "POST", { code: invite.code, name: "Ben\nReader" }, 400);
  assert.equal((await a(club)).members.length, 1);
  assert.equal((await b("clubs/join", "POST", { code: `${invite.code.slice(0, 5)}-${invite.code.slice(5)}`, name: "  Night Owl  " })).id, clubID);
  await b("clubs/join", "POST", { code: invite.code });
  assert.equal((await a(club)).members.find(({ id }) => id === ben.account.id).name, "Night Owl");
  assert.equal((await b("me")).name, "Ben");
  const secondClub = `clubs/${(await a("clubs", "POST", { name: "Weekend readers" }, 201)).id}`;
  const secondInvite = await a(`${secondClub}/invite`, "POST");
  await b("clubs/join", "POST", { code: secondInvite.code, name: "Early Bird" });
  assert.equal((await a(secondClub)).members.find(({ id }) => id === ben.account.id).name, "Early Bird");
  assert.equal((await a(club)).members.find(({ id }) => id === ben.account.id).name, "Night Owl");
  await b(`${club}/invite`, "POST", undefined, 403);
  await b(`${club}/reads`, "POST", reading("Wrong book"), 403);
  await b(`${read}/checkpoints/${chapter.id}`, "PATCH", { label: "New label" }, 403);
  await a(`${read}/checkpoints/${chapter.id}`, "PATCH", { label: "Read through chapter 3" });

  const observed = Date.now();
  const { epoch } = await b(`${read}/sharing`, "PUT", { enabled: true, presence: true });
  await b(`${read}/progress`, "PUT", { epoch, fraction: 0.42, observedAt: observed, active: true });
  await b(`${read}/progress`, "PUT", { epoch, fraction: 0.11, observedAt: observed - 2000, active: false });
  const [position] = (await a(read)).progress;
  assert.equal(position.fraction, 0.42);
  assert.ok(position.activeUntil > Date.now());
  await b(`${read}/checkpoints/${chapter.id}/complete`, "PUT", {});
  await b(`${read}/checkpoints/${chapter.id}/complete`, "PUT", {});
  assert.deepEqual((await b("clubs")).find(({ id }) => id === clubID).nextCheckpoint,
    { label: finish.label, dueAt: finish.dueAt });
  assert.deepEqual((await a(club)).activity.filter((event) => event.kind === "checkpoint").map(({ memberName }) => memberName), ["Night Owl"]);
  await b(`${read}/sharing`, "PUT", { enabled: false, presence: false });
  await b(`${read}/progress`, "PUT", { epoch, fraction: 0.5, observedAt: Date.now(), active: true }, 409);
  await b(`${read}/checkpoints/${finish.id}/complete`, "PUT", { epoch }, 409);
  assert.equal((await a(read)).progress.length, 0);
  assert.equal((await a(read)).completions.length, 1);

  const thread = `${read}/threads/${chapter.id}`;
  const { id: postID } = await a(thread, "POST", { body: "What did everyone think?", passage: "A short excerpt.", passageChapter: "Chapter 3" }, 201);
  await outside(thread, "GET", undefined, 404);
  await b(`${read}/threads/general`, "POST", { body: "Wrong thread", parentID: postID }, 404);
  const { id: replyID } = await b(thread, "POST", { body: "My favorite part so far.", parentID: postID, isSpoiler: true }, 201);
  const feedReply = (await a("me/feed")).events.find(({ id }) => id === replyID);
  assert.deepEqual(feedReply.discussion, { clubID, readID: first.id, threadID: chapter.id, postID: replyID });
  const { focusedPost } = await a(thread + "?focus=" + replyID);
  assert.deepEqual([focusedPost.id, focusedPost.parentID, focusedPost.concealed, focusedPost.body], [replyID, postID, true, ""]);
  await b(`${read}/posts/${postID}/reaction`, "PUT", { emoji: "\ud83d\udcda", enabled: true });
  await b(`${read}/posts/${postID}/report`, "POST", { reason: "Test report" });
  const posts = (await b(thread)).posts;
  assert.equal(posts.length, 2);
  assert.equal(posts.find((post) => post.authorID === ben.account.id).authorName, "Night Owl");
  assert.equal(posts.find((post) => post.id === postID).reactions[0].accountID, ben.account.id);
  await b(`blocks/${alice.account.id}`, "PUT");
  assert.equal((await b(thread)).posts.length, 1);
  assert.equal((await a(thread)).posts.length, 1);
  await b(`blocks/${alice.account.id}`, "DELETE");
  assert.equal((await b(thread)).posts.length, 2);

  const { id: book1 } = await b(`${club}/nominations`, "POST", { name: "Dune", author: "Frank Herbert" }, 201);
  const { id: book2 } = await a(`${club}/nominations`, "POST", { name: "Kindred", author: "Octavia Butler" }, 201);
  const { id: pollID } = await a(`${club}/polls`, "POST", { name: "December book", optionIDs: [book1, book2] }, 201);
  await a(`${club}/polls/${pollID}/vote`, "PUT", { nominationID: book2 });
  await b(`${club}/polls/${pollID}/vote`, "PUT", { nominationID: book1 });
  const next = await a(`${club}/next`);
  assert.equal(next.nominations.find(({ id }) => id === book1).memberName, "Night Owl");
  assert.equal(next.polls[0].votes.length, 2);
  assert.equal(next.polls[0].votes.find(({ accountID }) => accountID === ben.account.id).memberName, "Night Owl");
  await a(`${club}/polls/${pollID}/close`, "POST", {}, 409);
  await a(`${club}/polls/${pollID}/close`, "POST", { winnerID: book1 });
  await b(`${club}/polls/${pollID}/vote`, "PUT", { nominationID: book2 }, 409);
  const second = await a(`${club}/reads`, "POST", { ...reading("Dune", "Frank Herbert"), pollID }, 201);
  await a(`${club}/reads`, "POST", { ...reading("Dune", "Frank Herbert"), pollID }, 409);
  assert.equal((await b(club)).reads[0].id, second.id);
  assert.ok((await b(club)).reads[1].closedAt);
  assert.equal((await b(thread)).posts.length, 2);
  await b(thread, "POST", { body: "Closed" }, 409);

  await a(`${club}/host`, "PUT", { memberID: ben.account.id });
  await a(`${club}/invite`, "DELETE", undefined, 403);
  await b(`${club}/members/${alice.account.id}`, "DELETE");
  await a(club, "GET", undefined, 404);
  await a(thread, "GET", undefined, 404);
  await a("clubs/join", "POST", { code: invite.code }, 404);
  await outside("clubs/join", "POST", { code: invite.code });
  assert.equal((await b(club)).members.find(({ id }) => id === clara.account.id).name, "Clara");
  assert.equal((await outside(thread)).posts.length, 2, "late join sees shared history");
  await b(`${club}/invite`, "DELETE");
  await outside(`${club}/leave`, "POST");
  await outside(club, "GET", undefined, 404);
});

test("account recovery, revocation, and deletion use separate credentials", async () => {
  const owner = await createAccount("Recoverable Reader");
  const old = client(owner.token);
  assert.equal((await old("me")).id, owner.account.id);
  const second = await request("sessions", { method: "POST", body: { recoveryKey: owner.recoveryKey }, status: 201 });
  const restored = client(second.token);
  const { recoveryKey } = await restored("me/recovery", "POST");
  await old("me", "GET", undefined, 401);
  await request("sessions", { method: "POST", body: { recoveryKey: owner.recoveryKey }, status: 401 });
  const fresh = await request("sessions", { method: "POST", body: { recoveryKey }, status: 201 });
  await restored("me/session", "DELETE");
  await restored("me", "GET", undefined, 401);
  await client(fresh.token)("me", "DELETE");
  await request("sessions", { method: "POST", body: { recoveryKey }, status: 401 });
});
