import { createHash, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { HTTPError } from "../http.mjs";
import { atomFeed, searchTemplate } from "./atom.mjs";

const types = new Set(["opds", "grimmory", "audiobookshelf", "book-club"]);
const formats = new Set(["ebook", "audiobook", "unknown"]);
const sourcePattern = /^[a-z0-9][a-z0-9-]{0,47}$/u;
const mediaAccept = "application/opds+json, application/atom+xml, application/opensearchdescription+xml, application/json";
const pageSize = 50;
const fileTypes = {
  epub: ["ebook", "application/epub+zip"], pdf: ["ebook", "application/pdf"],
  mp3: ["audiobook", "audio/mpeg"], m4a: ["audiobook", "audio/mp4"], m4b: ["audiobook", "audio/mp4"],
};

function string(value, max = 160) {
  if (typeof value !== "string") return "";
  return [...value.replace(/[\p{Cc}\p{Zl}\p{Zp}]/gu, " ").trim()].slice(0, max).join("");
}

function publication(source, { id, title, author, series, format }) {
  title = string(title);
  if (!title) return null;
  author = string(author, 120) || null;
  return {
    id: createHash("sha256").update(JSON.stringify([source, string(id, 1024) || [title, author]])).digest("hex"),
    title, author, series: string(series, 120) || null, format: formats.has(format) ? format : "unknown",
  };
}

function name(value) {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map(name).filter(Boolean).join(", ");
  if (!value || typeof value !== "object") return "";
  if (value.name) return name(value.name);
  return Object.values(value).find((translation) => typeof translation === "string" && translation.trim()) ?? "";
}

function matches(query, record) {
  const words = query.toLowerCase().split(/\s+/u);
  const searchable = [record.title, record.author, record.series].filter(Boolean).join(" ").toLowerCase();
  return words.every((word) => searchable.includes(word));
}

function mediaFormat(links, type = "") {
  if (/audiobook/iu.test(type) || links.some((link) => /^audio\/|audiobook/iu.test(link.type ?? ""))) return "audiobook";
  if (links.some((link) => /epub|pdf|mobipocket|comic|fb2/iu.test(link.type ?? ""))) return "ebook";
  return "unknown";
}

function catalogURL(value, base) {
  if (typeof value !== "string" || !value || value.length > 2048) return null;
  try {
    const url = new URL(value, base);
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.hash || (base && url.origin !== base.origin)) return null;
    return url;
  } catch {
    return null;
  }
}

function baseEndpoint(base, path) {
  const target = new URL(base);
  target.pathname = target.pathname.replace(/\/+$/u, "") + "/" + path;
  target.search = "";
  return target;
}

function requiredSecret(key, env) {
  if (typeof key !== "string" || !/^[A-Z][A-Z0-9_]*$/u.test(key) || !env[key] || /[\r\n]/u.test(env[key])) {
    throw new Error("A catalog credential environment variable is missing or invalid.");
  }
  return env[key];
}

async function fetchUpstream(url, authorization, accept, signal) {
  const headers = { Accept: accept, "Accept-Encoding": "identity", ...(authorization ? { Authorization: authorization } : {}) };
  let response = await fetch(url, { signal, redirect: "manual", headers });
  for (let redirects = 0; [301, 302, 303, 307, 308].includes(response.status); redirects++) {
    await response.body?.cancel();
    const target = catalogURL(response.headers.get("location"), url);
    if (!target || redirects >= 3) throw new Error("The catalog redirect is unavailable.");
    url = target;
    response = await fetch(url, { signal, redirect: "manual", headers });
  }
  if (response.status !== 200 || !response.body) {
    await response.body?.cancel();
    throw new HTTPError(502, "The provider could not deliver this file or catalog.");
  }
  return { response, url };
}

async function fetchDocument(url, authorization) {
  const { response, url: finalURL } = await fetchUpstream(url, authorization, mediaAccept, AbortSignal.timeout(8000));
  const reader = response.body.getReader();
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let size = 0;
  let contents = "";
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) return { contents: contents + decoder.decode(), url: finalURL };
      size += value.byteLength;
      if (size > 2_097_152) throw new Error("The catalog response is too large.");
      contents += decoder.decode(value, { stream: true });
    }
  } finally {
    await reader.cancel().catch(() => {});
  }
}

const isAcquisition = (link) => (Array.isArray(link.rel) ? link.rel : [link.rel]).some((rel) =>
  /^https?:\/\/opds-spec\.org\/acquisition(?:\/open-access)?$/u.test(rel ?? ""));

function directFiles(links, base) {
  return links.filter(isAcquisition).flatMap((link) => {
    if (link.properties?.indirectAcquisition || link.templated) return [];
    const url = catalogURL(link.href, base);
    if (!url) return [];
    const type = (link.type ?? "").split(";")[0].toLowerCase();
    const ext = /\.([a-z0-9]+)$/iu.exec(url.pathname)?.[1].toLowerCase();
    const matched = { "application/epub+zip": "epub", "application/pdf": "pdf", "audio/mpeg": "mp3",
      "audio/mp4": ext === "m4b" ? "m4b" : "m4a", "audio/m4b": "m4b", "audio/x-m4b": "m4b", "audio/x-m4a": "m4a" }[type];
    const extension = matched ?? ((!type || type === "application/octet-stream") && Object.hasOwn(fileTypes, ext) ? ext : null);
    return extension ? [{ url, extension }] : [];
  });
}

function parseOPDS(contents) {
  if (contents.trimStart().startsWith("{")) {
    const feed = JSON.parse(contents);
    const groups = [feed, ...(Array.isArray(feed.groups) ? feed.groups : [])];
    return {
      links: feed.links ?? [],
      search: (feed.links ?? []).find(hasRel("search")),
      publications: groups.flatMap((group) => group.publications ?? []).map(({ metadata, links = [] }) => ({
        id: metadata?.identifier,
        title: name(metadata?.title),
        author: name(metadata?.author),
        series: name(metadata?.belongsTo?.series ?? metadata?.belongsTo?.collection),
        format: mediaFormat(links, metadata?.["@type"]),
        links,
      })),
      navigation: groups.flatMap((group) => group.navigation ?? []).map((link) => ({ title: name(link.title), href: link.href })),
    };
  }
  const feed = atomFeed(contents);
  const publications = [];
  const navigation = [];
  for (const { id, title, author, links } of feed.entries) {
    const acquisition = links.filter((link) => /^https?:\/\/opds-spec\.org\/acquisition(?:\/|$)/u.test(link.rel ?? ""));
    if (acquisition.length) {
      publications.push({ id, title, author, format: mediaFormat(acquisition), links: acquisition });
    } else {
      const link = links.find((link) => /application\/(?:atom\+xml|opds\+json)/u.test(link.type ?? ""));
      if (link) navigation.push({ title, href: link.href });
    }
  }
  return { links: feed.links, search: feed.links.find(hasRel("search")), publications, navigation };
}

const hasRel = (rel) => (link) => (Array.isArray(link.rel) ? link.rel : [link.rel]).includes(rel);

async function searchLink(link, feedURL, query, authorization) {
  if (!link?.href) return null;
  let template = link.href;
  let base = feedURL;
  if (link.type?.includes("opensearchdescription")) {
    base = catalogURL(link.href, feedURL);
    if (!base) return null;
    const document = await fetchDocument(base, authorization);
    base = document.url;
    template = searchTemplate(document.contents);
  }
  if (!template || !/\{searchTerms\??\}|\{\?query\}|\{query\}/u.test(template)) return null;
  const resolved = template.replace(/\{searchTerms\??\}|\{query\}/gu, encodeURIComponent(query))
    .replace(/\{\?query\}/gu, "?query=" + encodeURIComponent(query))
    .replace(/\{count\??\}/gu, String(pageSize)).replace(/\{(?:startPage|startIndex)\??\}/gu, "1")
    .replace(/\{[\w:]+\?\}/gu, "");
  return /[{}]/u.test(resolved) ? null : catalogURL(resolved, base);
}

async function opds(source, query, state, authorization, grimmory) {
  const url = new URL(state ?? source.url);
  if (grimmory && !state) {
    url.searchParams.set("size", String(pageSize));
    if (query) url.searchParams.set("q", query);
  }
  let document = await fetchDocument(url, authorization);
  let feed = parseOPDS(document.contents);
  if (!grimmory && query && !state && feed.search) {
    const target = await searchLink(feed.search, document.url, query, authorization);
    if (target) {
      document = await fetchDocument(target, authorization);
      feed = parseOPDS(document.contents);
    }
  }
  return {
    publications: feed.publications.map((item) => ({ ...item, files: directFiles(item.links, document.url) })),
    navigation: feed.navigation.map(({ title, href }) => ({ title, state: catalogURL(href, document.url)?.href })).filter((item) => item.state),
    next: catalogURL(feed.links.find(hasRel("next"))?.href, document.url)?.href,
  };
}

async function audiobookshelf(source, query, state, authorization) {
  const page = state ?? 0;
  const path = "api/libraries/" + encodeURIComponent(source.libraryId) + "/";
  const url = baseEndpoint(source.url, path + (query ? "search" : "items"));
  url.searchParams.set("limit", String(pageSize));
  if (query) url.searchParams.set("q", query);
  else {
    url.searchParams.set("page", String(page));
    url.searchParams.set("minified", "1");
  }
  const data = JSON.parse((await fetchDocument(url, authorization)).contents);
  const items = query ? (data.book ?? []).map((result) => result.libraryItem) : data.results;
  if (!Array.isArray(items)) throw new Error("Invalid Audiobookshelf response.");
  return {
    publications: items.filter((item) => item?.media && item.mediaType !== "podcast").map(({ id, media }) => ({
      id, title: media.metadata?.title, author: media.metadata?.authorName || name(media.metadata?.authors),
      series: media.metadata?.seriesName || name(media.metadata?.series),
      format: media.duration > 0 || media.numAudioFiles > 0 || media.audioFiles?.length ? "audiobook" : media.ebookFile ? "ebook" : "unknown",
      audio: media.numTracks > 0 || media.duration > 0 || media.audioFiles?.length > 0,
      ebook: !!media.ebookFile || ["epub", "pdf"].includes(media.ebookFormat),
    })),
    next: !query && Number.isSafeInteger(data.total) && data.total > (page + 1) * pageSize ? page + 1 : undefined,
  };
}

async function external(source, query, state, authorization) {
  const url = new URL(source.url);
  if (query) url.searchParams.set("q", query);
  if (state) url.searchParams.set("cursor", state);
  const data = JSON.parse((await fetchDocument(url, authorization)).contents);
  if (!Array.isArray(data.publications)) throw new Error("Invalid catalog response.");
  return {
    publications: data.publications,
    next: typeof data.nextCursor === "string" && data.nextCursor.length <= 2048 ? data.nextCursor : undefined,
  };
}

async function absFiles(source, rawID, format, authorization) {
  const path = "api/items/" + encodeURIComponent(rawID);
  const detail = baseEndpoint(source.url, path);
  detail.searchParams.set("expanded", "1");
  const item = JSON.parse((await fetchDocument(detail, authorization)).contents);
  if (item.libraryId !== source.libraryId || item.mediaType !== "book") throw new HTTPError(404, "This book is unavailable in the configured library.");
  const entries = format === "ebook" ? [item.media?.ebookFile].filter(Boolean) :
    (item.media?.audioFiles ?? []).filter((entry) => !entry.exclude && !entry.isInvalid).sort((a, b) => a.index - b.index);
  const files = entries.map((entry) => {
    const filename = entry.metadata?.filename ?? "";
    const extension = /\.([a-z0-9]+)$/iu.exec(filename)?.[1].toLowerCase() ?? entry.ebookFormat;
    const inode = String(entry.ino ?? "");
    if (!Object.hasOwn(fileTypes, extension) || fileTypes[extension][0] !== format || !/^[a-z0-9_-]{1,100}$/iu.test(inode)) {
      throw new HTTPError(422, "This edition contains an unsupported file type.");
    }
    return { extension, url: baseEndpoint(source.url, path + "/file/" + encodeURIComponent(inode) + "/download") };
  });
  return files;
}

function downloadSource({ url, extension }, authorization) {
  const [, contentType] = fileTypes[extension];
  return {
    extension, contentType,
    async open(signal) {
      const { response } = await fetchUpstream(url, authorization, contentType + ", application/octet-stream", signal);
      const type = (response.headers.get("Content-Type") ?? "").split(";")[0].toLowerCase();
      const coding = response.headers.get("Content-Encoding");
      if ((coding && coding !== "identity") || ![contentType, "application/octet-stream",
        ...(extension === "m4a" || extension === "m4b" ? ["audio/x-m4a", "audio/x-m4b", "audio/m4a", "audio/m4b", "video/mp4"] : []),
      ].includes(type)) {
        await response.body.cancel();
        throw new HTTPError(422, "The provider did not return the selected file type.");
      }
      return response;
    },
  };
}

export function loadCatalogs(file, env = process.env) {
  if (!file) return new Map();
  const entries = JSON.parse(readFileSync(file, "utf8"));
  if (!Array.isArray(entries) || entries.length > 32) throw new Error("Catalog configuration must be a list of up to 32 sources.");
  const catalogs = new Map();
  for (const item of entries) {
    const id = item?.id;
    const label = string(item?.name, 72);
    const type = item?.type;
    const url = catalogURL(item?.url);
    if (typeof id !== "string" || !sourcePattern.test(id) || !label || !types.has(type) || !url || catalogs.has(id)) {
      throw new Error("A catalog entry has an invalid id, name, type or URL.");
    }
    if (item.tokenEnv && (item.usernameEnv || item.passwordEnv)) throw new Error("Choose one catalog authentication method.");
    const authorization = item.tokenEnv ? "Bearer " + requiredSecret(item.tokenEnv, env) :
      item.usernameEnv || item.passwordEnv ? "Basic " + Buffer.from(
        requiredSecret(item.usernameEnv, env) + ":" + requiredSecret(item.passwordEnv, env), "utf8").toString("base64") : null;
    if (type === "audiobookshelf" && (!string(item.libraryId, 128) || !authorization?.startsWith("Bearer "))) {
      throw new Error("Audiobookshelf requires a library ID and a bearer token environment variable.");
    }
    const source = { id, name: label, type, url: type === "grimmory" ? baseEndpoint(url, "api/v1/opds/catalog") : url, libraryId: item.libraryId };
    const cursors = new Map();
    const selections = new Map();
    const canShare = item.shareFiles === true && type !== "book-club";
    const issue = (state, query) => {
      if (state === undefined || state === null) return null;
      while (cursors.size >= 1024) cursors.delete(cursors.keys().next().value);
      const key = randomUUID();
      cursors.set(key, { state, query, expiry: Date.now() + 900_000 });
      return key;
    };
    catalogs.set(id, {
      ...source,
      ...(canShare ? { acquire(publicationID, format) {
        const choice = selections.get(publicationID);
        if (!choice || choice.expiry <= Date.now() || !choice.formats.includes(format)) {
          throw new HTTPError(404, "This catalog selection expired or cannot be hosted. Browse the catalog again.");
        }
        return {
          title: choice.title, format,
          async files() {
            const files = type === "audiobookshelf" ? await absFiles(source, choice.rawID, format, authorization) :
              choice.files.filter(({ extension }) => fileTypes[extension][0] === format).slice(0, 1);
            return files.map((file) => downloadSource(file, authorization));
          },
        };
      } } : {}),
      async browse(query, cursor) {
        const position = cursor && cursors.get(cursor);
        if (cursor && (!position || position.expiry < Date.now() || position.query !== query)) {
          throw new HTTPError(400, "This catalog page expired. Restart your search.");
        }
        try {
          const state = position?.state;
          const page = type === "audiobookshelf" ? await audiobookshelf(source, query, state, authorization) :
            type === "book-club" ? await external(source, query, state, authorization) :
            await opds(source, query, state, authorization, type === "grimmory");
          const publications = page.publications.slice(0, 100).filter(Boolean).flatMap((record) => {
            const book = publication(id, record);
            if (!book) return [];
            if (!canShare) return [book];
            const shareableFormats = type === "audiobookshelf" && typeof record.id === "string" && /^[a-z0-9_-]{1,100}$/iu.test(record.id) ?
              [record.ebook && "ebook", record.audio && "audiobook"].filter(Boolean) :
              [...new Set((record.files ?? []).map(({ extension }) => fileTypes[extension][0]))];
            if (shareableFormats.length) {
              while (selections.size >= 1024) selections.delete(selections.keys().next().value);
              selections.set(book.id, { title: book.title, rawID: record.id, files: record.files, formats: shareableFormats, expiry: Date.now() + 900_000 });
            }
            return [{ ...book, shareableFormats }];
          });
          return {
            publications: type === "opds" && query ? publications.filter((record) => matches(query, record)) : publications,
            navigation: (page.navigation ?? []).slice(0, 60).map(({ title, state }) => ({ title: string(title), cursor: issue(state, query) })),
            nextCursor: issue(page.next, query),
          };
        } catch {
          throw new HTTPError(502, "This catalog is temporarily unavailable.");
        }
      },
    });
  }
  return catalogs;
}
