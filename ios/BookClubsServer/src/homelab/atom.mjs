const atom = "http://www.w3.org/2005/Atom";
const opensearch = "http://a9.com/-/spec/opensearch/1.1/";
const predefined = { amp: "&", apos: "'", gt: ">", lt: "<", quot: '"' };

function decode(value) {
  return value.replace(/&(?:(amp|apos|gt|lt|quot|#[0-9]+|#x[0-9a-fA-F]+);)?/gu, (_, reference) => {
    if (!reference) throw new Error("Invalid XML entity.");
    if (Object.hasOwn(predefined, reference)) return predefined[reference];
    const hex = reference.startsWith("#x");
    const point = Number.parseInt(reference.slice(hex ? 2 : 1), hex ? 16 : 10);
    if (point > 0x10ffff || (point >= 0xd800 && point <= 0xdfff) || (point < 32 && ![9, 10, 13].includes(point))) {
      throw new Error("Invalid XML character.");
    }
    return String.fromCodePoint(point);
  });
}

function document(xml) {
  const tokens = /<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<(?:"[^"]*"|'[^']*'|[^<>"'])*>|[^<]+/gyu;
  const stack = [];
  let root;
  let offset = 0;
  while (offset < xml.length) {
    const match = tokens.exec(xml);
    if (!match) throw new Error("Invalid XML token.");
    offset = tokens.lastIndex;
    const [token] = match;
    const parent = stack.at(-1);
    if (token.startsWith("<?") || token.startsWith("<!--")) continue;
    if (!token.startsWith("<") || token.startsWith("<![CDATA[")) {
      const content = token.startsWith("<![CDATA[") ? token.slice(9, -3) : decode(token);
      if (parent) parent.content.push(content);
      else if (content.trim()) throw new Error("Invalid XML text.");
      continue;
    }
    if (token.startsWith("</")) {
      if (!parent || token.slice(2, -1).trim() !== parent.tag) throw new Error("Mismatched XML element.");
      stack.pop();
      continue;
    }
    const tag = /^<([A-Za-z_][\w.:-]*)/u.exec(token)?.[1];
    if (!tag || stack.length >= 40) throw new Error("Unsupported XML element.");
    const tagValues = token.slice(tag.length + 1, token.endsWith("/>") ? -2 : -1).trimEnd();
    const properties = /\s+([A-Za-z_][\w.:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/gyu;
    const attributes = Object.create(null);
    const namespaces = Object.create(parent?.namespaces ?? null);
    let index = 0;
    while (index < tagValues.length) {
      const property = properties.exec(tagValues);
      if (!property || Object.hasOwn(attributes, property[1])) throw new Error("Invalid XML attribute.");
      const [, name, doubleQuoted, singleQuoted] = property;
      const value = decode(doubleQuoted ?? singleQuoted);
      attributes[name] = value;
      if (name === "xmlns") namespaces[""] = value;
      if (name.startsWith("xmlns:")) namespaces[name.slice(6)] = value;
      index = properties.lastIndex;
    }
    const [prefix, local] = tag.includes(":") ? tag.split(":") : ["", tag];
    const node = { tag, local, namespace: namespaces[prefix], namespaces, attributes, content: [] };
    if (parent) parent.content.push(node);
    else if (root) throw new Error("The XML has multiple roots.");
    else root = node;
    if (!token.endsWith("/>")) stack.push(node);
  }
  if (!root || stack.length) throw new Error("Incomplete XML.");
  return root;
}

function elements(node, name, namespace = atom) {
  return node.content.filter((value) => typeof value !== "string" && value.local === name && value.namespace === namespace);
}

function value(node) {
  return node?.content.map((child) => typeof child === "string" ? child : value(child)).join("").trim() ?? "";
}

const links = (node) => elements(node, "link").map(({ attributes }) => attributes);

export function atomFeed(xml) {
  const feed = document(xml);
  if (feed.local !== "feed" || feed.namespace !== atom) throw new Error("An Atom feed is required.");
  return {
    links: links(feed),
    entries: elements(feed, "entry").map((entry) => ({
      id: value(elements(entry, "id")[0]),
      title: value(elements(entry, "title")[0]),
      author: elements(entry, "author").map((author) => value(elements(author, "name")[0])).filter(Boolean).join(", "),
      links: links(entry),
    })),
  };
}

export function searchTemplate(xml) {
  const root = document(xml);
  if (root.local !== "OpenSearchDescription" || root.namespace !== opensearch) return null;
  return elements(root, "Url", opensearch).find(({ attributes }) =>
    /application\/(?:atom\+xml|opds\+json)/u.test(attributes.type ?? ""))?.attributes.template ?? null;
}
