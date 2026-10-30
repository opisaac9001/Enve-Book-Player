#!/usr/bin/env bash
# Verifies the Enve OPDS WireMock fixture. Read-only apart from the progression writes,
# which mutate one WireMock scenario and are reset at the end.
set -euo pipefail

BASE_URL="${OPDS_FIXTURE_BASE_URL:-http://127.0.0.1:9091}"
SCENARIO="opds-progression-lab-ebook-001"
CONNECT_TIMEOUT=5
MAX_TIME=15
WITH_BINARIES=0
KEEP_SCENARIO=0

PASSED=0
FAILED=0
WARNED=0
SCENARIO_RESET=0
CHECK_OK=0

usage() {
  cat <<'USAGE'
Usage: verify-opds-fixture.sh [BASE_URL] [options]

  BASE_URL            Origin WireMock serves the fixture on.
                      Default: $OPDS_FIXTURE_BASE_URL, else http://127.0.0.1:9091

  --with-binaries     Also require the copied EPUB, PDF, CBZ, audio and cover files.
  --keep-scenario     Leave the progression scenario in whatever state the run produced.
  -h, --help          Print this message.

The script sends no credentials. The only writes are PUTs to the fixture's own
progression endpoints; nothing outside /opds and /__admin/scenarios is touched.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --with-binaries) WITH_BINARIES=1 ;;
    --keep-scenario) KEEP_SCENARIO=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    *) BASE_URL="$1" ;;
  esac
  shift
done

BASE_URL="${BASE_URL%/}"

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { printf '%s is required.\n' "$tool" >&2; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BODY="$WORK/body"
HEAD="$WORK/head"

section() { printf '\n== %s\n' "$1"; }
pass() { PASSED=$((PASSED + 1)); printf 'ok    %s\n' "$1"; }
warn() { WARNED=$((WARNED + 1)); printf 'warn  %s — %s\n' "$1" "${2:-}"; }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL  %s — %s\n' "$1" "${2:-}"; }

# request METHOD PATH [curl args...] -> prints the status code; body in $BODY, headers in $HEAD
request() {
  local method="$1" path="$2" code
  shift 2
  code="$(curl -sS -o "$BODY" -D "$HEAD" -w '%{http_code}' \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
    -X "$method" "$@" "$BASE_URL$path" 2>/dev/null || true)"
  [ -n "$code" ] || code="000"
  printf '%s' "$code"
}

# Never fails: an absent header is an empty value, and pipefail would otherwise abort the run.
header_value() {
  tr -d '\r' < "$HEAD" | grep -i "^$1:" | head -1 | sed 's/^[^:]*: *//' || true
}

content_type_is() {
  local actual
  actual="$(header_value content-type | tr 'A-Z' 'a-z')"
  case "$actual" in "$1"*) return 0 ;; *) return 1 ;; esac
}

body_size() { wc -c < "$BODY" | tr -d ' '; }

# check_get LABEL PATH STATUS CONTENT_TYPE_PREFIX [jq filter] -> sets CHECK_OK
check_get() {
  local label="$1" path="$2" want_status="$3" want_type="$4" filter="${5:-}" code
  CHECK_OK=0
  code="$(request GET "$path")"
  if [ "$code" != "$want_status" ]; then
    fail "$label" "expected HTTP $want_status, got $code"
    return 0
  fi
  if [ -n "$want_type" ] && ! content_type_is "$want_type"; then
    fail "$label" "expected Content-Type $want_type, got $(header_value content-type)"
    return 0
  fi
  if [ -n "$filter" ] && ! jq -e "$filter" "$BODY" >/dev/null 2>&1; then
    fail "$label" "body did not satisfy: $filter"
    return 0
  fi
  CHECK_OK=1
  pass "$label"
}

body_contains() {
  if grep -qF -- "$2" "$BODY"; then
    pass "$1"
  else
    fail "$1" "response did not contain: $2"
  fi
}

printf 'Enve OPDS fixture verification\n'
printf 'base url: %s\n' "$BASE_URL"

section "reachability"
code="$(request GET "/__admin/mappings?limit=1")"
case "$code" in
  200) pass "WireMock admin API answers" ;;
  000) fail "WireMock admin API answers" "no response from $BASE_URL" ;;
  *) warn "WireMock admin API answers" "HTTP $code; continuing against the stub endpoints" ;;
esac

section "OPDS 2.0 catalog"
check_get "root feed" /opds/v2/root.json 200 "application/opds+json" \
  '.metadata.title and ((.publications | length) >= 8)'
if [ "$CHECK_OK" = "1" ]; then
  cp "$BODY" "$WORK/root.json"
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    label="${spec%%|*}"
    filter="${spec#*|}"
    if jq -e "$filter" "$WORK/root.json" >/dev/null 2>&1; then
      pass "root feed carries $label"
    else
      fail "root feed carries $label" "filter failed: $filter"
    fi
  done <<'FILTERS'
a self link|[.links[].rel] | index("self")
a start link|[.links[].rel] | index("start")
a next link|[.links[].rel] | index("next")
a first link|[.links[].rel] | index("first")
a last link|[.links[].rel] | index("last")
a templated search link|([.links[] | select(.rel == "search" and .templated == true)] | length) == 1
navigation|(.navigation | length) >= 4
groups|(.groups | length) >= 2
a group self link|([.groups[].links // [] | .[] | select(.rel == "self")] | length) >= 1
group navigation|([.groups[].navigation // [] | .[]] | length) >= 1
facets|(.facets | length) >= 2
catalogs|(.catalogs | length) >= 1
a localized title|([.publications[] | select(.metadata.title | type == "object")] | length) >= 1
a belongsTo series|([.publications[] | select(.metadata.belongsTo.series != null)] | length) >= 1
images on every publication|([.publications[] | select(((.images // []) | length) > 0)] | length) >= 8
a thumbnail image|([.publications[].images[] | select(.rel == "http://opds-spec.org/image/thumbnail")] | length) >= 1
a direct ebook acquisition|([.publications[].links[] | select(.rel == "http://opds-spec.org/acquisition" and .type == "application/epub+zip")] | length) >= 1
an open-access acquisition|([.publications[].links[] | select(.rel == "http://opds-spec.org/acquisition/open-access")] | length) >= 1
a direct audiobook acquisition|([.publications[].links[] | select(.rel == "http://opds-spec.org/acquisition" and (.type | startswith("audio/")))] | length) >= 1
an audiobook duration|([.publications[] | select(.metadata.duration != null)] | length) >= 1
an LCP protected publication|([.publications[].links[] | select(.type == "application/vnd.readium.lcp.license.v1.0+json")] | length) >= 1
an unsupported Readium package|([.publications[].links[] | select(.type == "application/audiobook+zip")] | length) >= 1
a buy link with a price|([.publications[].links[] | select(.rel == "http://opds-spec.org/acquisition/buy" and .properties.price.currency != null and .properties.price.value != null)] | length) >= 1
a borrow link with copies, holds and availability|([.publications[].links[] | select(.rel == "http://opds-spec.org/acquisition/borrow" and .properties.copies.total != null and .properties.holds.total != null and .properties.availability.state != null)] | length) >= 1
a subscribe link|([.publications[].links[] | select(.rel == "http://opds-spec.org/acquisition/subscribe")] | length) >= 1
a progression service|([.publications[].links[] | select(.rel == "http://opds-spec.org/progression" and .type == "application/opds-progression+json")] | length) >= 1
a progression authenticate hint|([.publications[].links[] | select(.rel == "http://opds-spec.org/progression" and .properties.authenticate.href != null)] | length) >= 1
only host-relative acquisition hrefs|([.publications[].links[] | select(.href | startswith("http"))] | length) == 0
FILTERS
fi

check_get "second page" /opds/v2/page2.json 200 "application/opds+json" \
  '([.links[].rel] | index("previous")) and (([.links[].rel] | index("next")) == null) and ((.publications | length) >= 2)'
check_get "single publication document" /opds/v2/publication/lab-ebook-001.json 200 \
  "application/opds-publication+json" '.metadata.title and ((.links | length) >= 3)'
check_get "ebooks sub-feed" /opds/v2/nav/ebooks.json 200 "application/opds+json" '(.publications | length) >= 2'
check_get "audiobooks sub-feed" /opds/v2/nav/audiobooks.json 200 "application/opds+json" '(.publications | length) >= 2'
check_get "progression sub-feed" /opds/v2/nav/progression.json 200 "application/opds+json" \
  '([.publications[].links[] | select(.rel == "http://opds-spec.org/progression")] | length) >= 6'
check_get "edge-case sub-feed" /opds/v2/nav/edge-cases.json 200 "application/opds+json" '(.publications | length) >= 10'
check_get "group feed" /opds/v2/group/new-releases.json 200 "application/opds+json" '(.publications | length) >= 2'
check_get "catalog feed" /opds/v2/catalog/partner.json 200 "application/opds+json" '.metadata.title'
check_get "language facet feed" /opds/v2/facet/language-en.json 200 "application/opds+json" '.metadata.title'
check_get "sort facet feed" /opds/v2/facet/sort-title.json 200 "application/opds+json" '.metadata.title'
check_get "search feed" "/opds/v2/search.json?query=harbour" 200 "application/opds+json" '(.publications | length) >= 1'

section "OPDS 1.2 catalog"
check_get "Atom root" /opds/v1/root.xml 200 "application/atom+xml" ""
if [ "$CHECK_OK" = "1" ]; then
  body_contains "Atom root advertises OpenSearch" 'type="application/opensearchdescription+xml"'
  body_contains "Atom root carries a navigation entry" 'rel="subsection"'
  body_contains "Atom root carries an acquisition entry" 'rel="http://opds-spec.org/acquisition"'
fi
check_get "Atom acquisition feed" /opds/v1/acquisition.xml 200 "application/atom+xml" ""
if [ "$CHECK_OK" = "1" ]; then
  body_contains "Atom feed paginates" 'rel="next"'
  body_contains "Atom feed carries a price" '<opds:price currencycode="USD">'
  body_contains "Atom feed carries availability" '<opds:availability status='
  body_contains "Atom feed carries copies" '<opds:copies total='
  body_contains "Atom feed carries holds" '<opds:holds total='
  body_contains "Atom feed carries indirect acquisition" '<opds:indirectAcquisition type='
  body_contains "Atom feed carries schema:Series" '<schema:Series schema:name='
  body_contains "Atom feed carries a progression service" 'rel="http://opds-spec.org/progression"'
  body_contains "Atom feed carries an audio acquisition" 'type="audio/mpeg"'
  body_contains "Atom feed carries an Adobe DRM acquisition" 'application/vnd.adobe.adept+xml'
fi
check_get "Atom second page" /opds/v1/acquisition-page2.xml 200 "application/atom+xml" ""
if [ "$CHECK_OK" = "1" ]; then
  body_contains "Atom second page links back" 'rel="previous"'
fi
check_get "Atom entry document" /opds/v1/entry/lab-ebook-101.xml 200 "application/atom+xml" ""
check_get "OpenSearch description" /opds/v1/opensearch.xml 200 "application/opensearchdescription+xml" ""
if [ "$CHECK_OK" = "1" ]; then
  body_contains "OpenSearch template carries searchTerms" '{searchTerms}'
  if grep -q '{{' "$BODY"; then
    fail "OpenSearch template is rendered" "response templating did not run; the body still contains {{ }}"
  else
    pass "OpenSearch template is rendered"
  fi
  if grep -qE 'template="https?://[^"]+"' "$BODY"; then
    pass "OpenSearch template is absolute"
  else
    fail "OpenSearch template is absolute" "no absolute template URL in the description"
  fi
fi
check_get "Atom search results" "/opds/v1/search.xml?q=harbour" 200 "application/atom+xml" ""

section "authentication"
check_get "basic authentication document" /opds/auth/basic.json 200 "application/opds-authentication+json" \
  '.id and .title and ([.authentication[].type] | index("http://opds-spec.org/auth/basic"))'
check_get "OAuth password authentication document" /opds/auth/oauth-password.json 200 "application/opds-authentication+json" \
  '(([.authentication[] | select(.type == "http://opds-spec.org/auth/oauth/password")] | length) == 1)
   and (([.authentication[] | select(.type == "http://opds-spec.org/auth/oauth/password") | .links[].rel] | index("authenticate")) != null)
   and (([.authentication[] | select(.type == "http://opds-spec.org/auth/oauth/password") | .links[].rel] | index("refresh")) != null)'
check_get "OAuth implicit authentication document" /opds/auth/oauth-implicit.json 200 "application/opds-authentication+json" \
  '(([.authentication[] | select(.type == "http://opds-spec.org/auth/oauth/implicit")] | length) == 1)
   and (([.authentication[] | select(.type == "http://opds-spec.org/auth/oauth/implicit") | .links[].rel] | index("authenticate")) != null)
   and (([.authentication[] | select(.type == "http://opds-spec.org/auth/oauth/implicit") | .links[].rel] | index("refresh")) != null)'

code="$(request GET /opds/v2/protected.json)"
if [ "$code" = "401" ] && content_type_is "application/opds-authentication+json" && [ -n "$(header_value www-authenticate)" ]; then
  pass "OPDS 2 protected feed answers 401 with an authentication document"
else
  fail "OPDS 2 protected feed answers 401 with an authentication document" \
    "HTTP $code, Content-Type $(header_value content-type), WWW-Authenticate '$(header_value www-authenticate)'"
fi

code="$(request GET /opds/v1/protected.xml)"
if [ "$code" = "401" ] && content_type_is "application/opds-authentication+json"; then
  pass "OPDS 1 protected feed answers 401 with an authentication document"
else
  fail "OPDS 1 protected feed answers 401 with an authentication document" "HTTP $code"
fi

code="$(request GET /opds/v2/gated.json)"
if [ "$code" = "401" ]; then
  pass "gated feed refuses a request with no Authorization header"
else
  fail "gated feed refuses a request with no Authorization header" "HTTP $code"
fi

code="$(request GET /opds/v2/gated.json -H "Authorization: Bearer opds-fixture-verification")"
if [ "$code" = "200" ] && jq -e '(.publications | length) >= 1' "$BODY" >/dev/null 2>&1; then
  pass "gated feed serves a request that carries any Authorization header"
else
  fail "gated feed serves a request that carries any Authorization header" "HTTP $code"
fi

code="$(request POST /opds/auth/oauth/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data "grant_type=password&username=placeholder&password=placeholder")"
if [ "$code" = "200" ] && jq -e '.access_token and .refresh_token and (.token_type == "Bearer")' "$BODY" >/dev/null 2>&1; then
  pass "OAuth password grant returns a token pair"
else
  fail "OAuth password grant returns a token pair" "HTTP $code"
fi

code="$(request POST /opds/auth/oauth/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data "grant_type=refresh_token&refresh_token=placeholder")"
if [ "$code" = "200" ] && jq -e '.access_token and .refresh_token' "$BODY" >/dev/null 2>&1; then
  pass "OAuth refresh grant returns a token pair"
else
  fail "OAuth refresh grant returns a token pair" "HTTP $code"
fi

code="$(request GET "/opds/auth/oauth/authorize?redirect_uri=enve%3A%2F%2Foauth%2Fcallback&state=verify")"
location="$(header_value location)"
case "$code:$location" in
  302:*access_token=*) pass "OAuth implicit grant redirects with a token fragment" ;;
  *) fail "OAuth implicit grant redirects with a token fragment" "HTTP $code, Location '$location'" ;;
esac

section "OPDS Progression 1.0"
code="$(request PUT "/__admin/scenarios/$SCENARIO/state" \
  -H "Content-Type: application/json" --data '{"state":"Started"}')"
case "$code" in
  200|204) SCENARIO_RESET=1; pass "progression scenario set to Started" ;;
  *) warn "progression scenario set to Started" "HTTP $code; this WireMock may not support per-scenario state" ;;
esac

code="$(request GET /opds/progression/lab-ebook-001)"
if [ "$code" = "200" ] && content_type_is "application/opds-progression+json" && [ ! -s "$BODY" ]; then
  pass "GET with no recorded position answers 200 and an empty payload"
elif [ "$SCENARIO_RESET" = "0" ]; then
  warn "GET with no recorded position answers 200 and an empty payload" \
    "the scenario is still in the state an earlier run left it in"
else
  fail "GET with no recorded position answers 200 and an empty payload" \
    "HTTP $code, Content-Type $(header_value content-type), $(body_size) byte body"
fi

cat > "$WORK/progression-valid.json" <<'JSON'
{
  "title": "Verification write",
  "modified": "2026-09-19T11:00:00.000Z",
  "device": {
    "id": "urn:uuid:00000000-0000-4000-8000-000000000001",
    "name": "verify-opds-fixture"
  },
  "progression": 0.5,
  "references": ["chapter3.xhtml#par36"]
}
JSON

cat > "$WORK/progression-invalid.json" <<'JSON'
{
  "modified": "yesterday afternoon",
  "device": { "id": "", "name": "" },
  "progression": 1.7
}
JSON

code="$(request PUT /opds/progression/lab-ebook-001 \
  -H "Content-Type: application/opds-progression+json" \
  --data-binary "@$WORK/progression-valid.json")"
if [ "$code" = "201" ] && content_type_is "application/opds-progression+json" \
  && jq -e '(.progression == 0.5) and (.device.name == "verify-opds-fixture")' "$BODY" >/dev/null 2>&1; then
  pass "first valid PUT answers 201 with the settled document"
else
  fail "first valid PUT answers 201 with the settled document" \
    "HTTP $code, Content-Type $(header_value content-type)"
fi

code="$(request GET /opds/progression/lab-ebook-001)"
if [ "$code" = "200" ] && content_type_is "application/opds-progression+json" \
  && jq -e '.modified and .device.id and (.device.name != "") and (.progression >= 0) and (.progression <= 1) and ((.references | type) == "array")' \
    "$BODY" >/dev/null 2>&1; then
  pass "GET after the write answers 200 with a progression document"
else
  fail "GET after the write answers 200 with a progression document" \
    "HTTP $code, Content-Type $(header_value content-type)"
fi

code="$(request PUT /opds/progression/lab-ebook-001 \
  -H "Content-Type: application/opds-progression+json" \
  --data-binary "@$WORK/progression-valid.json")"
if [ "$code" = "200" ] && jq -e '.progression == 0.5' "$BODY" >/dev/null 2>&1; then
  pass "second valid PUT answers 200 with the settled document"
else
  fail "second valid PUT answers 200 with the settled document" "HTTP $code"
fi

code="$(request PUT /opds/progression/lab-ebook-001 \
  -H "Content-Type: application/opds-progression+json" \
  --data-binary "@$WORK/progression-invalid.json")"
if [ "$code" = "400" ] && content_type_is "application/problem+json" \
  && jq -e '.type == "https://registry.opds.io/error#progression-invalid-payload"' "$BODY" >/dev/null 2>&1; then
  pass "a schema-breaking PUT answers 400 progression-invalid-payload"
else
  fail "a schema-breaking PUT answers 400 progression-invalid-payload" \
    "HTTP $code, Content-Type $(header_value content-type)"
fi

code="$(request PUT /opds/progression/lab-ebook-001 \
  -H "Content-Type: application/json" \
  --data-binary "@$WORK/progression-valid.json")"
if [ "$code" = "400" ]; then
  pass "a PUT with the wrong Content-Type answers 400"
else
  fail "a PUT with the wrong Content-Type answers 400" "HTTP $code"
fi

code="$(request GET /opds/progression/lab-audiobook-001)"
if [ "$code" = "200" ] && jq -e '([.references[] | select(startswith("#t="))] | length) == 1' "$BODY" >/dev/null 2>&1; then
  pass "the audiobook service reports a media-fragment reference"
else
  fail "the audiobook service reports a media-fragment reference" "HTTP $code"
fi

code="$(request GET /opds/progression/lab-ebook-101)"
if [ "$code" = "200" ] && jq -e '(.references | length) >= 3' "$BODY" >/dev/null 2>&1; then
  pass "the OPDS 1 service reports an ordered reference list"
else
  fail "the OPDS 1 service reports an ordered reference list" "HTTP $code"
fi

code="$(request PUT /opds/progression/lab-conflict-001 \
  -H "Content-Type: application/opds-progression+json" \
  --data-binary "@$WORK/progression-valid.json")"
if [ "$code" = "409" ] && content_type_is "application/problem+json" \
  && jq -e '.type == "https://registry.opds.io/error#progression-date"' "$BODY" >/dev/null 2>&1; then
  pass "a stale PUT answers 409 progression-date"
else
  fail "a stale PUT answers 409 progression-date" "HTTP $code, Content-Type $(header_value content-type)"
fi

code="$(request GET /opds/progression/lab-conflict-001)"
if [ "$code" = "200" ] && jq -e '.modified == "2026-09-19T09:05:00.000Z"' "$BODY" >/dev/null 2>&1; then
  pass "the conflicting service reports the newer point on GET"
else
  fail "the conflicting service reports the newer point on GET" "HTTP $code"
fi

code="$(request GET /opds/progression/lab-malformed-001)"
if [ "$code" = "200" ] && content_type_is "application/opds-progression+json" \
  && jq -e '(.progression > 1) or (.device.name == "") or ((.references | type) != "array")' "$BODY" >/dev/null 2>&1; then
  pass "the malformed service answers 200 with a document that fails the schema"
else
  fail "the malformed service answers 200 with a document that fails the schema" "HTTP $code"
fi

code="$(request PUT /opds/progression/lab-malformed-001 \
  -H "Content-Type: application/opds-progression+json" \
  --data-binary "@$WORK/progression-valid.json")"
if [ "$code" = "200" ] && [ ! -s "$BODY" ]; then
  pass "the malformed service answers PUT with an empty success body"
else
  fail "the malformed service answers PUT with an empty success body" "HTTP $code, $(body_size) byte body"
fi

code="$(request GET /opds/progression/lab-protected-001)"
if [ "$code" = "401" ] && content_type_is "application/opds-authentication+json"; then
  pass "the protected service answers 401 with an authentication document"
else
  fail "the protected service answers 401 with an authentication document" \
    "HTTP $code, Content-Type $(header_value content-type)"
fi

check_get "published progression schema" /opds/progression/progression.schema.json 200 "application/schema+json" \
  '(.required | index("progression")) != null'

if [ "$KEEP_SCENARIO" = "0" ]; then
  code="$(request PUT "/__admin/scenarios/$SCENARIO/state" \
    -H "Content-Type: application/json" --data '{"state":"Started"}')"
  case "$code" in
    200|204) pass "progression scenario restored to Started" ;;
    *) warn "progression scenario restored to Started" "HTTP $code; the next GET returns a document rather than an empty payload" ;;
  esac
fi

section "malformed and redirect targets"
code="$(request GET /opds/malformed/html-as-feed)"
if [ "$code" = "200" ] && content_type_is "text/html"; then
  pass "a catalog URL that answers with HTML is reachable"
else
  fail "a catalog URL that answers with HTML is reachable" "HTTP $code, Content-Type $(header_value content-type)"
fi

code="$(request GET /opds/malformed/not-a-feed.json)"
if [ "$code" = "200" ] && content_type_is "application/opds+json" \
  && jq -e '(has("metadata") | not)' "$BODY" >/dev/null 2>&1; then
  pass "JSON that is not an OPDS feed is served with an OPDS content type"
else
  fail "JSON that is not an OPDS feed is served with an OPDS content type" "HTTP $code"
fi

code="$(request GET /opds/malformed/truncated.json)"
if [ "$code" = "200" ] && ! jq -e . "$BODY" >/dev/null 2>&1; then
  pass "truncated JSON is served and does not parse"
else
  fail "truncated JSON is served and does not parse" "HTTP $code"
fi

code="$(request GET /opds/malformed/truncated-atom.xml)"
if [ "$code" = "200" ] && content_type_is "application/atom+xml"; then
  pass "truncated Atom is served with an Atom content type"
else
  fail "truncated Atom is served with an Atom content type" "HTTP $code, Content-Type $(header_value content-type)"
fi

code="$(request GET /opds/malformed/html-declared-atom.xml)"
if [ "$code" = "200" ] && content_type_is "application/atom+xml" && grep -qi '<!doctype html' "$BODY"; then
  pass "an HTML body declared as Atom is served"
else
  fail "an HTML body declared as Atom is served" "HTTP $code, Content-Type $(header_value content-type)"
fi

request_host="${BASE_URL#*://}"
request_host="${request_host%%/*}"
code="$(request GET /opds/redirect/cross-origin/epub)"
location="$(header_value location)"
location_host="${location#*://}"
location_host="${location_host%%/*}"
if [ "$code" = "302" ] && [ -n "$location_host" ] && [ "$location_host" != "$request_host" ]; then
  pass "the cross-origin acquisition redirects to another origin ($location_host)"
else
  fail "the cross-origin acquisition redirects to another origin" "HTTP $code, Location '$location'"
fi

code="$(request GET /opds/redirect/same-origin/epub)"
location="$(header_value location)"
case "$code:$location" in
  302:/opds/files/*) pass "the same-origin acquisition redirects within the origin" ;;
  *) fail "the same-origin acquisition redirects within the origin" "HTTP $code, Location '$location'" ;;
esac

code="$(request GET /opds/echo/headers)"
if [ "$code" = "200" ] && jq -e '.credentialHeadersPresent.authorization == false' "$BODY" >/dev/null 2>&1; then
  pass "the echo endpoint reports no credential header on a bare request"
else
  fail "the echo endpoint reports no credential header on a bare request" "HTTP $code"
fi

code="$(request GET /opds/echo/headers -H "Authorization: Bearer opds-fixture-verification")"
if [ "$code" = "200" ] && jq -e '.credentialHeadersPresent.authorization == true' "$BODY" >/dev/null 2>&1; then
  pass "the echo endpoint reports an Authorization header when one is sent"
else
  fail "the echo endpoint reports an Authorization header when one is sent" "HTTP $code"
fi

section "acquisition bodies"
check_get "Readium audiobook manifest" /opds/files/lab-audiobook-004.json 200 "application/audiobook+json" \
  '(.readingOrder | length) >= 1'
check_get "LCP licence stub" /opds/files/lab-ebook-004.lcpl 200 "application/vnd.readium.lcp.license.v1.0+json" '.id'
code="$(request GET /opds/buy/lab-buy-001)"
if [ "$code" = "200" ] && content_type_is "text/html"; then
  pass "transactional acquisition pages answer with HTML"
else
  fail "transactional acquisition pages answer with HTML" "HTTP $code"
fi

if [ "$WITH_BINARIES" = "1" ]; then
  check_binary() {
    local label="$1" path="$2" want_type="$3" code length
    code="$(request GET "$path")"
    length="$(body_size)"
    if [ "$code" = "200" ] && content_type_is "$want_type" && [ "$length" -gt 0 ]; then
      pass "$label ($length bytes)"
    else
      fail "$label" "HTTP $code, Content-Type $(header_value content-type), $length bytes"
    fi
  }
  check_binary "cover image" /opds/images/cover-blue.png "image/png"
  check_binary "second cover image" /opds/images/cover-amber.png "image/png"
  check_binary "thumbnail image" /opds/images/thumb-blue.png "image/png"
  check_binary "first EPUB" /opds/files/lab-ebook-001.epub "application/epub+zip"
  check_binary "second EPUB" /opds/files/lab-ebook-002.epub "application/epub+zip"
  check_binary "PDF" /opds/files/lab-ebook-003.pdf "application/pdf"
  check_binary "CBZ" /opds/files/lab-comic-001.cbz "application/vnd.comicbook+zip"
  check_binary "MP3" /opds/files/lab-audiobook-001.mp3 "audio/mpeg"
  check_binary "M4B" /opds/files/lab-audiobook-002.m4b "audio/mp4"
else
  warn "copied binary bodies" "skipped; rerun with --with-binaries once the files are in __files/opds"
fi

printf '\n%s passed, %s failed, %s warnings\n' "$PASSED" "$FAILED" "$WARNED"
[ "$FAILED" -eq 0 ]
