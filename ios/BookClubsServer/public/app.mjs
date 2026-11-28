const app = document.querySelector("#app");
const accountBar = document.querySelector("#account");
const status = document.querySelector("#status");
const sessionKey = "enve.book-club.session";
let session = JSON.parse(sessionStorage.getItem(sessionKey) ?? "null");
let recoveryKey;
let restore = false;
let clubs = [];
let clubID;
let readID;
let section = "Reading";
let thread = "general";
let revealThread = false;
let discussionPath;
let feedDiscussion;
let revealedPosts = new Set();
let revealNotes = false;
let noteToEdit;
let notePage;
let feedPage;
let reply;
let sourceID;
let catalogQuery = "";
let catalogCursor;
let startDraft;
let toastTimer;
let version = 0;
let fieldCount = 0;
let availableFeatures;

function node(tag, attributes = {}, ...children) {
  const element = document.createElement(tag);
  for (const [name, value] of Object.entries(attributes)) {
    if (value !== false && value != null) element.setAttribute(name, value === true ? "" : String(value));
  }
  for (const child of children.flat(Infinity)) {
    if (child != null && child !== false) element.append(child);
  }
  return element;
}

const title = (text) => node("h2", {}, text);
const quiet = (text) => node("p", { class: "quiet" }, text);
const panel = (...children) => node("section", { class: "panel" }, ...children);
const line = (...children) => node("div", { class: "line" }, ...children);
const list = (items) => node("ul", { class: "rows" }, items.map((item) => node("li", {}, item)));
const label = (text, control) => {
  const id = "field-label-" + ++fieldCount;
  control.setAttribute("aria-labelledby", id);
  return node("label", {}, node("span", { id }, text), control);
};
const input = (text, name, options = {}) => label(text, node("input", { name, ...options }));
const area = (text, name, value = "", options = {}) => label(text, node("textarea", { name, ...options }, value));
const choices = (text, name, options, selected) => label(text, node("select", { name },
  options.map(([value, labelText]) => node("option", { value, selected: String(value) === String(selected) }, labelText))));

function toast(message, error = false) {
  clearTimeout(toastTimer);
  status.hidden = false;
  status.textContent = message;
  status.classList.toggle("error", error);
  if (!error) toastTimer = setTimeout(() => { status.hidden = true; }, 4200);
}

async function perform(control, action) {
  if (control) control.disabled = true;
  status.hidden = true;
  try {
    await action();
  } catch (error) {
    if (error.status === 401 && session) {
      saveSession(null);
      await render();
    }
    toast(error.message, true);
  } finally {
    if (control) control.disabled = false;
  }
}

function button(text, action, attributes = {}) {
  const control = node("button", { type: "button", ...attributes }, text);
  control.addEventListener("click", () => perform(control, action));
  return control;
}

function form(text, action, ...contents) {
  const submit = node("button", { type: "submit", class: "primary" }, text);
  const element = node("form", {}, contents, submit);
  element.addEventListener("submit", (event) => {
    event.preventDefault();
    const data = new FormData(element);
    perform(submit, () => action(data));
  });
  return element;
}

async function api(path, method = "GET", data) {
  const response = await fetch("/v1/" + path, {
    method,
    headers: { ...(session ? { Authorization: "Bearer " + session.token } : {}),
      ...(data !== undefined ? { "Content-Type": "application/json" } : {}) },
    ...(data !== undefined ? { body: JSON.stringify(data) } : {}),
  });
  const result = await response.json();
  if (!response.ok) {
    const error = new Error(result.error ?? "This request could not be completed.");
    error.status = response.status;
    throw error;
  }
  return result;
}

function saveSession(credentials) {
  session = credentials ? { account: credentials.account, token: credentials.token } : null;
  if (session) sessionStorage.setItem(sessionKey, JSON.stringify(session));
  else {
    sessionStorage.removeItem(sessionKey);
    clubs = [];
    clubID = undefined;
    readID = undefined;
    section = "Reading";
    resetRead();
    feedPage = undefined;
    recoveryKey = undefined;
  }
}

function invite() {
  return new URLSearchParams(location.hash.slice(1)).get("join") ?? "";
}

function inviteLink(code) {
  const url = new URL("/", location.href);
  url.hash = new URLSearchParams({ join: code }).toString();
  return url.href;
}

function accountScreen() {
  const signIn = form(restore ? "Restore profile" : "Create profile", async (data) => {
    const credentials = restore ?
      await api("sessions", "POST", { recoveryKey: data.get("key") }) :
      await api("accounts", "POST", { name: data.get("name") });
    saveSession(credentials);
    recoveryKey = restore ? undefined : credentials.recoveryKey;
    await reloadClubs();
  }, restore ? input("Recovery key", "key", { type: "password", required: true, autocomplete: "off" }) :
    input("Your display name", "name", { autocomplete: "nickname", maxlength: 36, required: true }));
  return node("div", { class: "auth stack" },
    node("header", {}, node("span", { class: "eyebrow" }, invite() ? "Club invitation" : "Read together"),
      node("h1", {}, invite() ? "Join a book club" : "A place to read together")),
    panel(title(restore ? "Restore your profile" : "Set up your profile"), signIn,
      button(restore ? "Create a new profile" : "I have a recovery key", () => { restore = !restore; return render(); })));
}

function keyPanel() {
  if (!recoveryKey) return null;
  return panel(title("Save your recovery key"),
    quiet("Keep it private. It restores your Clubs profile on another device."),
    node("div", { class: "key" }, recoveryKey),
    button("Done", () => { recoveryKey = undefined; return render(); }));
}

function resetDiscussion() {
  discussionPath = undefined;
  revealThread = false;
  revealedPosts = new Set();
  reply = undefined;
}

function resetRead() {
  feedDiscussion = undefined;
  thread = "general";
  resetDiscussion();
  revealNotes = false;
  noteToEdit = undefined;
  notePage = undefined;
}

function selectSection(next) {
  if (section === "Discussion" && next !== "Discussion") {
    feedDiscussion = undefined;
    resetDiscussion();
  }
  section = next;
}

function openThread(id) {
  if (thread !== id) {
    feedDiscussion = undefined;
    resetDiscussion();
  }
  thread = id;
  section = "Discussion";
  return render();
}

function selectClub(id) {
  clubID = id;
  readID = undefined;
  section = "Reading";
  startDraft = undefined;
  sourceID = undefined;
  catalogQuery = "";
  catalogCursor = undefined;
  resetRead();
}

async function reloadClubs() {
  clubs = await api("clubs");
  if (!clubID || !clubs.some(({ id }) => id === clubID)) selectClub(clubs[0]?.id);
  await render();
}

function joinPanel() {
  return panel(title("Join a club"),
    form("Join club", async (data) => {
      const name = data.get("name").trim();
      const result = await api("clubs/join", "POST", { code: data.get("code"), ...(name === session.account.name ? {} : { name }) });
      history.replaceState(null, "", "/");
      selectClub(result.id);
      await reloadClubs();
    }, input("Invite code", "code", { required: true, value: invite(), autocomplete: "off", autocapitalize: "characters" }),
    input("Name to show in this club", "name", { required: true, value: session.account.name, maxlength: 36, autocomplete: "nickname" })));
}

function clubsPanel() {
  return node("div", { class: "pair" }, joinPanel(),
    panel(title("Start a club"), form("Create club", async (data) => {
      const result = await api("clubs", "POST", { name: data.get("name") });
      selectClub(result.id);
      await reloadClubs();
    }, input("Club name", "name", { required: true, maxlength: 72 }))));
}

function sidebar() {
  return node("aside", { class: "sidebar" }, title("Your clubs"),
    node("nav", { "aria-label": "Your clubs" }, clubs.map((club) => button(club.name, () => {
      selectClub(club.id);
      return render();
    }, { "aria-current": club.id === clubID && !["Manage clubs", "My notes", "Club Feed"].includes(section) ? "page" : undefined })),
    availableFeatures?.includes("club-feed") && button("Club Feed", () => {
      selectSection("Club Feed");
      feedPage = undefined;
      return render();
    }, { "aria-current": section === "Club Feed" ? "page" : undefined }),
    button("Start or join a club", () => { selectSection("Manage clubs"); return render(); }),
    button("My notes", () => { selectSection("My notes"); notePage = undefined; return render(); })));
}

function day(value) {
  return value == null ? "" : new Intl.DateTimeFormat(undefined, { dateStyle: "medium" }).format(value);
}

function feedHeadline({ memberName, kind, label }) {
  const member = memberName ?? "A member";
  switch (kind) {
    case "readStarted": return `${member} started ${label}`;
    case "checkpoint": return `${member} reached ${label}`;
    case "pollClosed": return label ? `${member} closed the vote for ${label}` : `${member} closed the vote`;
    case "planChanged": return `${member} updated the reading plan`;
    case "post": return `${member} posted about ${label}`;
    default: return label || "Club activity";
  }
}

async function openFeedEvent(event) {
  selectClub(event.clubID);
  if (event.discussion) {
    feedDiscussion = event.discussion;
    readID = feedDiscussion.readID;
    thread = feedDiscussion.threadID;
    section = "Discussion";
  }
  await render();
  window.scrollTo(0, 0);
}

async function clubFeed() {
  const params = new URLSearchParams();
  if (feedPage) params.set("before", feedPage);
  const { events, before } = await api("me/feed" + (params.size ? "?" + params : ""));
  return panel(title("Club Feed"), events.length ? list(events.map((event) => node("article", { class: "between" },
    node("div", {}, node("strong", {}, feedHeadline(event)), quiet(event.clubName + " · " + day(event.createdAt))),
    button(event.discussion ? "Open discussion" : "Open " + event.clubName, () => openFeedEvent(event))))) :
    quiet("Activity from your clubs will appear here."),
  line(feedPage && button("Newest activity", () => { feedPage = undefined; return render(); }),
    before && button("Older activity", () => { feedPage = before; return render(); })));
}

const clubPath = (id) => "clubs/" + id;
const readPath = (club, id) => clubPath(club.id) + "/reads/" + id;
const isHost = (club) => club.ownerID === session.account.id;

function formatName(format) {
  return format === "audiobook" ? "audiobook" : "ebook";
}

function fileSize(bytes) {
  const [unit, divisor] = bytes >= 1e9 ? ["gigabyte", 1e9] : bytes >= 1e6 ? ["megabyte", 1e6] :
    bytes >= 1e3 ? ["kilobyte", 1e3] : ["byte", 1];
  return new Intl.NumberFormat(undefined, { style: "unit", unit, maximumFractionDigits: 1 }).format(bytes / divisor);
}

function hostCopy(club, id, source, book, format) {
  return api(readPath(club, id) + "/copy", "POST", { sourceID: source, publicationID: book.id, format });
}

function startRead(club) {
  const draft = startDraft ?? {};
  return panel(title("Start a reading"),
    form("Start reading", async (data) => {
      const checkpoints = data.get("checkpoints").split("\n").map((text) => text.trim()).filter(Boolean).map((label) => ({ label }));
      const result = await api(clubPath(club.id) + "/reads", "POST", {
        title: data.get("title"), author: data.get("author") || null, series: draft.series ?? null,
        checkpoints, pollID: draft.pollID ?? null,
      });
      let copyError;
      const format = data.get("hostFormat");
      if (format) {
        try {
          await hostCopy(club, result.id, draft.sourceID, draft, format);
        } catch (error) {
          copyError = error;
        }
      }
      startDraft = undefined;
      readID = result.id;
      section = "Reading";
      resetRead();
      await reloadClubs();
      if (copyError) toast("Reading started, but the club copy couldn’t be imported. " + copyError.message, true);
    }, input("Book title", "title", { value: draft.title, maxlength: 160, required: true, readonly: !!draft.pollID }),
    input("Author", "author", { value: draft.author, maxlength: 120, readonly: !!draft.pollID }),
    area("Checkpoints, one per line", "checkpoints", "", { maxlength: 2400 }),
    draft.shareableFormats?.length > 0 && choices("Club copy", "hostFormat",
      [["", "Members bring their own copies"], ...draft.shareableFormats.map((format) => [format, "Host " + formatName(format)])], "")),
    button("Cancel", () => { startDraft = undefined; section = "Reading"; return render(); }));
}

function downloadForm(base, copy, file) {
  const sessionField = node("input", { type: "hidden", name: "session" });
  sessionField.value = session.token;
  const filePath = base + "/" + encodeURIComponent(copy.id) + "/files/" + encodeURIComponent(file.index);
  return node("form", { class: "copy-download", method: "post", action: "/v1/" + filePath, target: "_blank", rel: "noopener" },
    sessionField, node("button", { type: "submit" }, "Download " + (copy.files.length === 1 ? formatName(copy.format) : file.name)));
}

async function hostedCopyPanel(club, reading, hosting) {
  const { read, hostedCopy } = reading;
  if (!hosting && !hostedCopy) return null;
  const base = readPath(club, read.id) + "/copy";
  const host = hosting && isHost(club);
  const initial = hosting ? await api(base) : { copy: hostedCopy };
  if (!initial.copy && !initial.importing && !host) return null;
  const view = panel();

  function schedule(state) {
    setTimeout(() => { if (view.isConnected) refresh(state); }, 2000);
  }

  async function refresh(previous, force = false) {
    try {
      const updated = await api(base);
      if (!view.isConnected) return;
      if (force || updated.importing !== previous.importing || updated.copy?.id !== previous.copy?.id ||
          updated.error !== previous.error) paint(updated);
      else if (updated.importing) schedule(updated);
    } catch (error) {
      if (view.isConnected) paint(previous, error.message);
    }
  }

  function paint(state, refreshError) {
    const { copy, importing, error } = state;
    view.replaceChildren(title("Club copy"),
      copy ? node("div", {},
        node("strong", {}, copy.title), quiet(copy.format === "audiobook" ? "Audiobook" : "Ebook"),
        list(copy.files.map((file) => node("div", { class: "between" },
          node("div", {}, file.name, quiet(fileSize(file.bytes))), downloadForm(base, copy, file)))))
        : quiet(importing ? "The club copy will be available when the import is complete." : "Members can bring their own copies."),
      importing && node("p", { role: "status" }, copy ? "Importing a replacement copy…" : "Importing the club copy…"),
      error && host && node("p", { role: "status" }, error),
      refreshError && [quiet(refreshError), button("Check status", () => refresh(state, true))],
      line(
        host && !read.closedAt && !importing && button(copy ? "Replace from catalog" : "Choose from catalog", () => {
          section = "Catalogs";
          return render();
        }),
        host && copy && !importing && button("Remove club copy", async () => {
          if (!confirm("Remove the hosted copy for this reading? Members’ saved downloads will remain on their devices.")) return;
          await api(base, "DELETE");
          await render();
        }, { class: "danger" })));
    if (importing && !refreshError) schedule(state);
  }

  paint(initial);
  return view;
}

function readingPanels(club, reading, copyPanel) {
  if (!reading) return panel(title("No book selected"), isHost(club) &&
    button("Start a reading", () => { section = "Start reading"; return render(); }, { class: "primary" }));
  const { read, progress, completions, checkpoints, sharing } = reading;
  const base = readPath(club, read.id);
  const completed = new Set(completions.filter(({ accountID }) => accountID === session.account.id).map(({ checkpointID }) => checkpointID));
  const positionPanel = panel(title("Reading together"), list(club.members.map((member) => {
    const position = progress.find(({ accountID }) => accountID === member.id);
    const checked = checkpoints.filter(({ id }) => completions.some((entry) => entry.accountID === member.id && entry.checkpointID === id)).at(-1);
    const percentage = position && Math.round(position.fraction * 100);
    return node("div", {}, node("strong", {}, member.name),
      position && node("div", {}, node("progress", { value: percentage, max: 100, "aria-label": member.name + " reading progress" }), " " + percentage + "%"),
      quiet(position?.activeUntil > Date.now() ? "Reading now" : checked?.label ?? (position ? "Sharing progress" : "No shared progress")));
  })), !read.closedAt && form("Share progress", async (data) => {
    const settings = sharing?.epoch ? sharing : await api(base + "/sharing", "PUT", { enabled: true, presence: false });
    await api(base + "/progress", "PUT", { epoch: settings.epoch, fraction: Number(data.get("percent")) / 100, observedAt: Date.now(), active: false });
    await render();
  }, input("My progress (%)", "percent", { type: "number", min: 0, max: 100, required: true,
    value: Math.round((progress.find(({ accountID }) => accountID === session.account.id)?.fraction ?? 0) * 100) })),
  !read.closedAt && sharing?.epoch && button("Stop sharing progress", async () => {
    await api(base + "/sharing", "PUT", { enabled: false, presence: false });
    await render();
  }));
  const readingPlan = panel(title("Reading plan"), checkpoints.length ? list(checkpoints.map((step) => node("div", {},
    node("strong", {}, step.label), step.dueAt && quiet(day(step.dueAt)), line(
      button("Discuss " + step.label, () => openThread(step.id)),
      !read.closedAt && !completed.has(step.id) && button("Check in at " + step.label, async () => {
        await api(base + "/checkpoints/" + step.id + "/complete", "PUT", {});
        await render();
      }), completed.has(step.id) && node("span", { class: "quiet" }, "Completed"))))) : quiet("There are no checkpoints for this reading."),
  !read.closedAt && isHost(club) && form("Add checkpoint", async (data) => {
    const date = data.get("due");
    await api(base + "/checkpoints", "POST", { label: data.get("label"), dueAt: date ? new Date(date + "T23:59:00").getTime() : null });
    await render();
  }, input("Checkpoint", "label", { maxlength: 100, required: true }), input("Due date", "due", { type: "date" })));
  return node("div", { class: "stack" },
    panel(node("div", { class: "between" },
      node("div", {}, node("span", { class: "eyebrow" }, read.closedAt ? "Past reading" : "Now reading"), title(read.title), read.author && quiet(read.author)),
      isHost(club) && button("Start another reading", () => { section = "Start reading"; return render(); }))),
    copyPanel,
    node("div", { class: "pair" }, readingPlan, positionPanel));
}

function discussionPrompt(path, prompt, canEdit) {
  if (!prompt && !canEdit) return null;
  return node("section", { class: "discussion-prompt" },
    node("h3", {}, "Pinned prompt"),
    prompt && node("p", { class: "pre" }, prompt.body),
    canEdit && node("details", {},
      node("summary", {}, prompt ? "Edit prompt" : "Add prompt"),
      form("Save prompt", async (data) => {
        await api(path + "/prompt", "PUT", { body: data.get("body") });
        await render();
      }, area("Discussion prompt", "body", prompt?.body, { required: true, maxlength: 1000 }))),
    canEdit && prompt && button("Remove prompt", async () => {
      if (!confirm("Remove the pinned discussion prompt?")) return;
      await api(path + "/prompt", "DELETE");
      await render();
    }, { class: "danger" }));
}

function discussionPost(base, post, archived, reveals) {
  const article = node("article", {},
    node("strong", {}, post.authorName), quiet(day(post.createdAt)),
    post.concealed ?
      line(node("span", { class: "quiet" }, "Spoiler hidden."),
        button("Reveal spoiler", () => { reveals.add(post.id); return render(); })) :
      [
        post.isSpoiler && line(node("span", { class: "quiet" }, "Contains spoilers"),
          reveals.has(post.id) && button("Hide spoiler", () => {
            reveals.delete(post.id);
            const { id, authorName, createdAt } = post;
            article.replaceWith(discussionPost(base, { id, authorName, createdAt, concealed: true }, archived, reveals));
            return render();
          })),
        post.body && node("p", { class: "pre" }, post.body),
        post.passage && node("blockquote", { class: "pre" }, post.passage, post.passageChapter && quiet(post.passageChapter)),
        line(["\u2764\ufe0f", "\ud83d\ude02", "\ud83d\ude2e", "\ud83d\udc4f", "\ud83d\udcda"].map((emoji) => {
          const reactions = post.reactions.filter((reaction) => reaction.emoji === emoji);
          const enabled = reactions.some(({ accountID }) => accountID === session.account.id);
          return button(emoji + (reactions.length ? " " + reactions.length : ""), async () => {
            await api(base + "/posts/" + post.id + "/reaction", "PUT", { emoji, enabled: !enabled });
            await render();
          }, { "aria-pressed": String(enabled), "aria-label": "React " + emoji });
        }), !archived && button("Reply to " + post.authorName, () => {
          reply = post.id;
          return render();
        })),
      ]);
  return article;
}

async function discussion(club, reading) {
  if (!reading) return panel(title(feedDiscussion ? "This reading is no longer available." : "Choose a reading to start a discussion"));
  const step = reading.checkpoints.find(({ id }) => id === thread);
  if (feedDiscussion && thread !== "general" && !step) return panel(title("This discussion is no longer available."));
  const base = readPath(club, reading.read.id);
  const path = base + "/threads/" + thread;
  if (discussionPath !== path) {
    resetDiscussion();
    discussionPath = path;
  }
  const tabs = line(["general", ...reading.checkpoints.map(({ id }) => id)].map((id) =>
    button(id === "general" ? "General discussion" : reading.checkpoints.find((entry) => entry.id === id).label,
      () => openThread(id), { "aria-pressed": String(thread === id) })));
  if (step && !revealThread && !reading.completions.some(({ accountID, checkpointID }) =>
    accountID === session.account.id && checkpointID === step.id)) {
    return panel(title("Discussion"), tabs, quiet("Check in at this checkpoint or reveal the discussion when you’re ready for spoilers."),
      button("Reveal discussion", () => { revealThread = true; return render(); }, { class: "primary" }));
  }
  const reveals = revealedPosts;
  const focus = feedDiscussion?.postID;
  const { posts: page, archived, discussionTools, prompt, focusedPost } =
    await api(path + (focus ? "?" + new URLSearchParams({ focus }) : ""));
  const posts = focusedPost ? [focusedPost, ...page.filter(({ id }) => id !== focusedPost.id)] : page;
  const currentIDs = new Set(posts.map(({ id }) => id));
  for (const id of reveals) {
    if (!currentIDs.has(id)) reveals.delete(id);
  }
  const visiblePosts = (await Promise.all(posts.map(async (post) => {
    if (!post.concealed || !reveals.has(post.id)) return post;
    try {
      return await api(base + "/posts/" + post.id);
    } catch (error) {
      reveals.delete(post.id);
      if (error.status === 404 || error.status === 403) return null;
      throw error;
    }
  }))).filter(Boolean);
  const currentReply = visiblePosts.find((post) => post.id === reply && !post.concealed);
  if (reveals === revealedPosts) reply = currentReply?.id;
  const target = focus && visiblePosts.find(({ id }) => id === focus);
  const otherPosts = visiblePosts.filter(({ id }) => id !== focus);
  return node("section", { class: "panel", "data-discussion": true }, title(step?.label ?? "Discussion"), tabs,
    focus && (target ? node("section", { class: "discussion-prompt" },
      node("h3", {}, "From Club Feed"), discussionPost(base, target, archived, reveals)) :
      quiet("This post is no longer available.")),
    discussionTools && discussionPrompt(path, prompt, !archived && isHost(club)),
    otherPosts.length ? list(otherPosts.map((post) => discussionPost(base, post, archived, reveals))) :
      !target && quiet("No posts yet."),
    !archived && form("Post", async (data) => {
      await api(path, "POST", {
        body: data.get("body"), passage: data.get("passage"), parentID: currentReply?.id,
        ...(discussionTools ? { isSpoiler: Boolean(currentReply?.isSpoiler || data.get("spoiler")) } : {}),
      });
      reply = undefined;
      await render();
    }, currentReply && line(node("span", {}, "Replying to " + currentReply.authorName), button("Cancel reply", () => { reply = undefined; return render(); })),
    area("Message", "body", "", { maxlength: 3000 }),
    discussionTools && (currentReply?.isSpoiler ? quiet("This reply will be hidden as a spoiler.") :
      input("Mark as spoiler", "spoiler", { type: "checkbox" })),
    node("details", {}, node("summary", {}, "Add a short passage"), area("Passage", "passage", "", { maxlength: 600 }))));
}

async function notes(club, reading) {
  const personal = !club;
  if (!personal && !reading) return panel(title("Choose a reading to take notes"));
  const base = personal ? "me/notes" : readPath(club, reading.read.id) + "/notes";
  const params = new URLSearchParams();
  if (!personal && revealNotes) params.set("revealSpoilers", "true");
  if (notePage) params.set("before", notePage);
  const data = await api(base + (params.size ? "?" + params : ""));
  const edit = noteToEdit;
  return node("div", { class: "stack" },
    !personal && panel(title(edit ? "Edit note" : "New note"), form(edit ? "Save note" : "Add note", async (fields) => {
      await api(base + (edit ? "/" + edit.id : ""), edit ? "PATCH" : "POST", {
        body: fields.get("body"), visibility: fields.get("visibility"), checkpointID: fields.get("checkpoint") || null,
      });
      noteToEdit = undefined;
      notePage = undefined;
      await render();
    }, area("Note", "body", edit?.body, { required: true, maxlength: 3000 }),
    choices("Visibility", "visibility", [["private", "Only me"], ["club", "Share with this club"]], edit?.visibility ?? "private"),
    choices("Checkpoint", "checkpoint", [["", "General"], ...reading.checkpoints.map(({ id, label }) => [id, label])], edit?.checkpointID ?? ""),
    edit && button("Cancel edit", () => { noteToEdit = undefined; return render(); }))),
    panel(node("div", { class: "between" }, title(personal ? "My notes" : "Reading notes"),
      !personal && button(revealNotes ? "Hide spoilers" : "Reveal shared spoilers", () => {
        revealNotes = !revealNotes; notePage = undefined; return render();
      }, { "aria-pressed": revealNotes })),
    data.notes.length ? list(data.notes.map((note) => {
      const own = note.authorID === session.account.id;
      const checkpoint = reading?.checkpoints.find(({ id }) => id === note.checkpointID);
      return node("article", {}, node("strong", {}, personal ? note.bookTitle : note.authorName),
        quiet([note.visibility === "private" ? "Only me" : "Shared with the club", checkpoint?.label, day(note.updatedAt)].filter(Boolean).join(" · ")),
        node("p", { class: "pre" }, note.body), own && line(
          !personal && button("Edit note", () => { noteToEdit = note; return render(); }),
          button("Delete note", async () => {
            if (!confirm("Delete this note?")) return;
            await api(base + "/" + note.id, "DELETE");
            await render();
          }, { class: "danger" })));
    })) : quiet(personal ? "Your notes will appear here." : "No notes are visible for this reading."),
    line(notePage && button("Newest notes", () => { notePage = undefined; return render(); }),
      data.before && button("Older notes", () => { notePage = data.before; return render(); }))));
}

async function catalog(club, hosting) {
  const base = clubPath(club.id) + "/catalog";
  const { sources } = await api(base);
  if (!sources.length) return panel(title("Catalogs"), quiet("This server has no shared catalogs."));
  if (!sources.some(({ id }) => id === sourceID)) sourceID = sources[0].id;
  const params = new URLSearchParams();
  if (catalogQuery) params.set("q", catalogQuery);
  if (catalogCursor) params.set("cursor", catalogCursor);
  const source = sourceID;
  const page = await api(base + "/" + source + (params.size ? "?" + params : ""));
  const host = isHost(club);
  const currentRead = club.reads.find(({ closedAt }) => closedAt == null);
  return panel(title("Catalogs"), line(sources.map((source) => button(source.name, () => {
    sourceID = source.id; catalogCursor = undefined; return render();
  }, { "aria-pressed": source.id === sourceID }))),
  form("Search", (data) => {
    catalogQuery = data.get("q").trim(); catalogCursor = undefined; return render();
  }, input("Search titles and authors", "q", { value: catalogQuery, maxlength: 120, type: "search" })),
  page.navigation.length > 0 && line(page.navigation.map(({ title, cursor }) => button(title, () => { catalogCursor = cursor; return render(); }))),
  page.publications.length ? list(page.publications.map((book) => {
    const formats = hosting ? book.shareableFormats ?? [] : [];
    const hostActions = host && currentRead && formats.map((format) => button(
      "Host " + formatName(format) + " for current reading", async () => {
        if (!confirm("Share the " + formatName(format) + " “" + book.title + "” with members reading “" + currentRead.title + "”?")) return;
        await hostCopy(club, currentRead.id, source, book, format);
        readID = currentRead.id;
        section = "Reading";
        resetRead();
        await render();
      }, { "aria-label": "Host " + book.title + " as an " + formatName(format) + " for the current reading" }));
    return node("div", { class: "between" },
      node("div", {}, node("strong", {}, book.title),
        quiet([book.author, book.format === "unknown" ? null : book.format].filter(Boolean).join(" · "))),
      line(button("Nominate " + book.title, async () => {
        await api(clubPath(club.id) + "/nominations", "POST", { name: book.title, author: book.author });
        toast("Nomination added.");
      }), host && button("Read " + book.title + " next", () => {
        startDraft = { ...book, sourceID: source, shareableFormats: formats };
        section = "Start reading";
        return render();
      }), hostActions));
  })) :
    !page.navigation.length && quiet("No books on this page."),
  line(catalogCursor && button("Catalog home", () => { catalogCursor = undefined; return render(); }),
    page.nextCursor && button("Next page", () => { catalogCursor = page.nextCursor; return render(); })));
}

async function voting(club) {
  const base = clubPath(club.id);
  const { nominations, polls } = await api(base + "/next");
  const nomination = (id) => nominations.find((book) => book.id === id);
  return node("div", { class: "stack" },
    panel(title("Nominations"), nominations.length > 0 && list(nominations.map(({ name, author, memberName }) =>
      node("div", {}, node("strong", {}, name), quiet([author, memberName && "Suggested by " + memberName].filter(Boolean).join(" · "))))),
    form("Nominate a book", async (data) => {
      await api(base + "/nominations", "POST", { name: data.get("name"), author: data.get("author") || null });
      await render();
    }, input("Book title", "name", { maxlength: 160, required: true }), input("Author", "author", { maxlength: 120 }))),
    isHost(club) && nominations.length >= 2 && !polls.some(({ closedAt }) => closedAt == null) &&
      panel(title("Start a vote"), form("Open vote", async (data) => {
        await api(base + "/polls", "POST", { name: data.get("name"), optionIDs: data.getAll("option") });
        await render();
      }, input("Poll title", "name", { maxlength: 100, required: true }), nominations.map(({ id, name }) =>
        input(name, "option", { type: "checkbox", value: id })))),
    polls.map((poll) => {
      const open = !poll.closedAt && (!poll.closesAt || poll.closesAt > Date.now());
      const count = (id) => poll.votes.filter(({ nominationID }) => nominationID === id).length;
      const top = Math.max(...poll.optionIDs.map(count));
      const leaders = poll.optionIDs.filter((id) => count(id) === top);
      const winner = nomination(poll.winnerID);
      return panel(title(poll.name), list(poll.optionIDs.map((id) => {
        const book = nomination(id);
        const voters = poll.votes.filter(({ nominationID }) => nominationID === id);
        return node("div", {}, open ? button("Vote for " + book.name, async () => {
          await api(base + "/polls/" + poll.id + "/vote", "PUT", { nominationID: id });
          await render();
        }, { "aria-pressed": voters.some(({ accountID }) => accountID === session.account.id) }) : node("strong", {}, book.name),
        quiet(voters.length + (voters.length === 1 ? " vote" : " votes") + (voters.length ? " · " + voters.map(({ memberName }) => memberName).join(", ") : "")));
      })), winner && quiet("Next pick: " + winner.name),
      isHost(club) && !poll.closedAt && form("Close vote", async (data) => {
        await api(base + "/polls/" + poll.id + "/close", "POST", { winnerID: data.get("winner") ?? null });
        await render();
      }, leaders.length > 1 && choices("Break the tie", "winner", leaders.map((id) => [id, nomination(id).name]), leaders[0])),
      winner && isHost(club) && !poll.startedReadID && button("Start " + winner.name, () => {
        startDraft = { title: winner.name, author: winner.author, pollID: poll.id };
        section = "Start reading";
        return render();
      }));
    }));
}

function pastReads(club) {
  const history = club.reads.filter((read) => read.closedAt != null);
  return panel(title("Past reads"), history.length ? list(history.map((read) => line(button(read.title, () => {
    readID = read.id; section = "Reading"; resetRead(); return render();
  }), read.author && node("span", { class: "quiet" }, read.author)))) : quiet("No past readings yet."));
}

function invitePanel(club) {
  const base = clubPath(club.id) + "/invite";
  const details = node("div", { class: "stack" });
  return panel(title("Invite members"), button("Generate invitation", async () => {
    const response = await api(base, "POST");
    const url = inviteLink(response.code);
    details.replaceChildren(input("Invitation link", "invite", { readonly: true, value: url }),
      quiet("Invite code: " + response.code + " · Expires " + day(response.expiresAt)),
      navigator.clipboard && button("Copy link", async () => { await navigator.clipboard.writeText(url); toast("Invitation copied."); }),
      button("Revoke invitation", async () => {
        await api(base, "DELETE");
        details.replaceChildren();
        toast("Invitation revoked.");
      }, { class: "danger" }));
  }), details);
}

async function clubScreen() {
  const club = await api(clubPath(clubID));
  const read = club.reads.find(({ id }) => id === readID) ??
    (feedDiscussion ? undefined : club.reads.find(({ closedAt }) => closedAt == null));
  const reading = read && ["Reading", "Discussion", "Notes"].includes(section) ? await api(readPath(club, read.id)) : null;
  const hosting = availableFeatures?.includes("hosted-copies");
  const nav = ["Reading", "Discussion", "Notes", "Catalogs", "Next book", "History", ...(isHost(club) ? ["Invite"] : [])];
  let content;
  switch (section) {
    case "Reading": content = readingPanels(club, reading, reading && await hostedCopyPanel(club, reading, hosting)); break;
    case "Discussion": content = await discussion(club, reading); break;
    case "Notes": content = await notes(club, reading); break;
    case "Catalogs": content = await catalog(club, hosting); break;
    case "Next book": content = await voting(club); break;
    case "History": content = pastReads(club); break;
    case "Invite": content = isHost(club) ? invitePanel(club) : null; break;
    case "Start reading": content = isHost(club) ? startRead(club) : null; break;
  }
  return node("div", { class: "stack" },
    node("header", {}, node("span", { class: "eyebrow" }, "Private book club"), node("h1", {}, club.name)),
    node("nav", { class: "tabs", "aria-label": "Club sections" }, nav.map((tab) => button(tab, () => {
      selectSection(tab);
      if (tab === "Reading") { readID = undefined; resetRead(); }
      return render();
    }, { "aria-current": section === tab ? "page" : undefined }))), content);
}

async function render() {
  const current = ++version;
  if (!session) {
    accountBar.replaceChildren();
    app.replaceChildren(accountScreen());
    app.inert = false;
    app.ariaBusy = "false";
    return;
  }
  accountBar.replaceChildren(line(node("span", {}, session.account.name), button("Sign out", async () => {
    await api("me/session", "DELETE");
    saveSession(null);
    await render();
  })));
  app.inert = true;
  app.ariaBusy = "true";
  try {
    availableFeatures ??= (await api("discovery")).features;
    let content;
    if (invite()) content = joinPanel();
    else if (section === "Club Feed") content = await clubFeed();
    else if (section === "My notes") content = await notes();
    else if (!clubID || section === "Manage clubs") content = clubsPanel();
    else content = await clubScreen();
    if (version === current) {
      app.replaceChildren(node("div", { class: "shell" }, sidebar(), node("div", { class: "work" }, keyPanel(), content)));
    }
  } catch (error) {
    if (version === current && (error.status === 403 || error.status === 404)) {
      const discussion = app.querySelector("[data-discussion]");
      if (discussion) {
        resetDiscussion();
        discussion.replaceChildren(quiet(error.message));
      }
    }
    throw error;
  } finally {
    if (version === current) {
      app.inert = false;
      app.ariaBusy = "false";
    }
  }
}

window.addEventListener("hashchange", () => perform(null, render));
perform(null, () => session ? reloadClubs() : render());
