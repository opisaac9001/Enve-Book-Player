import { HTTPError, response, text } from "./http.mjs";

export async function catalogRoutes(c) {
  const [root, club, section, sourceID] = c.path;
  if (root !== "clubs" || !club || section !== "catalog" || c.path.length > 4 || c.method !== "GET") return null;
  await c.requireMembership(club);
  const sources = c.env.CATALOGS ?? new Map();
  if (!sourceID) return response({ sources: [...sources.values()].map(({ id, name, type }) => ({ id, name, type })) });
  const source = sources.get(sourceID);
  if (!source) throw new HTTPError(404, "This catalog is unavailable.");
  await c.rateLimit("catalog", c.user, 60, 60_000);
  const query = text(c.url.searchParams.get("q"), 120, false) ?? "";
  const cursor = text(c.url.searchParams.get("cursor"), 4096, false);
  return response(await source.browse(query, cursor));
}
