export class HTTPError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export function response(value, status = 200) {
  return Response.json(value, { status, headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } });
}

export async function json(request) {
  let reader;
  try {
    reader = request.body.getReader();
    const decoder = new TextDecoder("utf-8", { fatal: true });
    let body = "";
    let length = 0;
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      length += value.length;
      if (length > 16384) {
        await reader.cancel();
        throw new HTTPError(413, "This update is too large.");
      }
      body += decoder.decode(value, { stream: true });
    }
    const value = JSON.parse(body + decoder.decode());
    if (value && typeof value === "object" && !Array.isArray(value)) return value;
  } catch (error) {
    if (error instanceof HTTPError) throw error;
  } finally {
    reader?.releaseLock();
  }
  throw new HTTPError(400, "Send a JSON object.");
}

export function text(value, max, required = true) {
  const trimmed = typeof value === "string" ? value.normalize("NFC").trim() : "";
  if (!required && (value == null || trimmed === "") && (value == null || typeof value === "string")) return null;
  if (!trimmed || [...trimmed].length > max || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(trimmed)) {
    throw new HTTPError(400, `Enter text between 1 and ${max} characters.`);
  }
  return trimmed;
}

export function date(value) {
  if (value == null) return null;
  if (Number.isSafeInteger(value) && value > 0 && value <= 8640000000000000) return value;
  throw new HTTPError(400, "Choose a valid date.");
}

export function fraction(value) {
  if (Number.isFinite(value) && value >= 0 && value <= 1) return value;
  throw new HTTPError(400, "Progress must be between 0% and 100%.");
}

export async function hash(value) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function code(length) {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  return Array.from(crypto.getRandomValues(new Uint8Array(length)), (byte) => alphabet[byte & 31]).join("");
}

export function normalizeCode(value, length) {
  const normalized = typeof value === "string" ? value.replace(/[\s-]/gu, "").toUpperCase() : "";
  if (normalized.length !== length || !/^[A-HJ-NP-Z2-9]+$/u.test(normalized)) {
    throw new HTTPError(400, "Check the code and try again.");
  }
  return normalized;
}

export function passFilter(env, ...values) {
  const simplified = values.filter(Boolean).join(" ").normalize("NFKC").toLowerCase();
  const words = new Set(simplified.split(/[^\p{L}\p{N}]+/u));
  const blocked = (env.CLUB_BLOCKED_WORDS ?? "").split(",").map((word) => word.trim().toLowerCase()).filter(Boolean);
  if (blocked.some((word) => words.has(word))) throw new HTTPError(422, "This text can’t be shared. Please edit it and try again.");
}
