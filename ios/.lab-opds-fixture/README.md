# Enve OPDS WireMock fixture

A deterministic OPDS test catalog for the lab's WireMock instance (`http://10.0.0.116:9091`,
`http://100.114.100.51:9091` over Tailscale). Every endpoint lives under `/opds`, so the fixture can be
added to and removed from the existing WireMock root without touching the RSS and API fixtures already
there.

Every href inside a feed is host-relative, so the same fixture serves the LAN address, the Tailscale address
and `localhost` without edits. The three places a relative URL is not usable — the OpenSearch template and
the two cross-origin redirect targets — are handled by response templating and by `Host`-matched stubs.

71 stubs across 8 mapping files.

## Layout

```
mappings/                       WireMock stub definitions, one file per area
  opds-v2-feeds.json            OPDS 2.0 catalog: root, page 2, sub-feeds, group, catalog, facets, search
  opds-v2-auth-gate.json        401 feed, credential-gated feed
  opds-v1-feeds.json            OPDS 1.2 Atom: root, acquisition pages, entry document, OpenSearch, 401 feed
  opds-auth-documents.json      Authentication documents, OAuth token and authorize endpoints
  opds-progression.json         OPDS Progression 1.0 (draft) service, including the GET-after-PUT scenario
  opds-malformed.json           HTML-as-feed, non-feed JSON, truncated JSON and Atom
  opds-redirects.json           Cross-origin and same-origin acquisition redirects, header-presence echo
  opds-binaries.json            Cover, EPUB, PDF, CBZ and audio bodies, LCP/ACSM/manifest stubs
__files/opds/                   Response bodies
  v2/                           OPDS 2.0 feeds and the single-publication document
  v1/                           Atom feeds, entry document, OpenSearch description
  auth/                         Authentication documents and the help/register page
  progression/                  Progression documents and the schema the fixture is shaped against
  malformed/                    Deliberately broken bodies
  echo/                         Templated credential-header presence report
  images/                       Cover art (copy in, see below)
  files/                        Publication bodies (copy in, see below)
bin/verify-opds-fixture.sh      curl + jq verification
```

## Deploying

WireMock's root on the lab is `/srv/enve-lab/repo/config/wiremock`. Copy the two served trees into it and
keep the script with the lab's other tooling:

```bash
cp -R mappings/. /srv/enve-lab/repo/config/wiremock/mappings/
cp -R __files/.  /srv/enve-lab/repo/config/wiremock/__files/
install -m 0755 bin/verify-opds-fixture.sh /srv/enve-lab/repo/bin/verify-opds-fixture
```

Then reload WireMock without restarting the container:

```bash
curl -sS -X POST http://127.0.0.1:9091/__admin/mappings/reset
```

`bin/lab restart wiremock` works too. Check the JSON before reloading — a malformed mapping file makes
WireMock drop the whole file:

```bash
find /srv/enve-lab/repo/config/wiremock/mappings -name 'opds-*.json' -exec jq -e . {} + > /dev/null
xmllint --noout /srv/enve-lab/repo/config/wiremock/__files/opds/v1/*.xml
bash -n /srv/enve-lab/repo/bin/verify-opds-fixture
```

The two `__files/opds/malformed/truncated*` bodies are invalid on purpose; exclude them from any bulk
validation.

## Binary bodies to copy in

The mappings reference these paths. Everything else in the fixture is complete as shipped.

| Expected path under `__files/` | Content type served | Source |
| --- | --- | --- |
| `opds/files/lab-ebook-001.epub` | `application/epub+zip` | a small DRM-free EPUB from `/srv/enve-lab/media/books` |
| `opds/files/lab-ebook-002.epub` | `application/epub+zip` | a second, different EPUB from `/srv/enve-lab/media/books` |
| `opds/files/lab-ebook-003.pdf` | `application/pdf` | a small PDF from `/srv/enve-lab/media/books` |
| `opds/files/lab-comic-001.cbz` | `application/vnd.comicbook+zip` | a small CBZ from `/srv/enve-lab/media/comics` |
| `opds/files/lab-audiobook-001.mp3` | `audio/mpeg` | a short single-file MP3 from `/srv/enve-lab/media/audiobooks` |
| `opds/files/lab-audiobook-002.m4b` | `audio/mp4` | a short M4B from `/srv/enve-lab/media/audiobooks` |
| `opds/files/lab-audiobook-003.audiobook` | `application/audiobook+zip` | any small zip; Enve refuses this format before downloading, so the bytes only matter to other clients |
| `opds/images/cover-blue.png` | `image/png` | cover art, or generate one |
| `opds/images/cover-amber.png` | `image/png` | cover art, or generate one |
| `opds/images/thumb-blue.png` | `image/png` | a 200×300 thumbnail, or generate one |

Keep each file small; WireMock holds response bodies in memory and does not stream them. A few megabytes for
the audio and under a megabyte for everything else is plenty.

Generated covers, if the corpus art is inconvenient:

```bash
cd /srv/enve-lab/repo/config/wiremock/__files/opds/images
ffmpeg -loglevel error -f lavfi -i color=c=0x121A2B:s=600x900 -frames:v 1 cover-blue.png
ffmpeg -loglevel error -f lavfi -i color=c=0x5E3612:s=600x900 -frames:v 1 cover-amber.png
ffmpeg -loglevel error -f lavfi -i color=c=0x121A2B:s=200x300 -frames:v 1 thumb-blue.png
```

Until the files exist, those URLs answer 500. The verification script skips them unless `--with-binaries`
is passed.

## Endpoints

### OPDS 2.0

| Endpoint | What it exercises |
| --- | --- |
| `GET /opds/v2/root.json` | feed metadata with a localized title; `self`, `start`, `first`, `last`, `next` and a templated `search`; navigation; 8 publications; a group with a preview and a `self` link plus a group with navigation; two facets; one catalog entry |
| `GET /opds/v2/page2.json` | second page, `previous`/`first`/`last`, no `next` |
| `GET /opds/v2/publication/lab-ebook-001.json` | single publication document, `application/opds-publication+json` |
| `GET /opds/v2/nav/ebooks.json` | PDF and CBZ acquisitions |
| `GET /opds/v2/nav/audiobooks.json` | M4B acquisition, Readium audiobook manifest (unsupported, listed) |
| `GET /opds/v2/nav/progression.json` | six publications whose progression links must and must not be adopted |
| `GET /opds/v2/nav/edge-cases.json` | sample-only, unavailable direct link, octet-stream with a typed path, indirect acquisition chain, no acquisition at all, Unicode and very long titles, a title map with no `en`, an HTML acquisition, both redirect acquisitions |
| `GET /opds/v2/group/new-releases.json` | the group's own collection; repeats one root publication so de-duplication is exercised |
| `GET /opds/v2/catalog/partner.json` | the catalog entry's target |
| `GET /opds/v2/facet/language-en.json`, `GET /opds/v2/facet/sort-title.json` | facet targets |
| `GET /opds/v2/search.json?query=…` | static result set for any query |
| `GET /opds/v2/gated.json` | 200 when the request carries any `Authorization` header, 401 with an authentication document otherwise |
| `GET /opds/v2/protected.json` | always 401 with `WWW-Authenticate: Basic` and a basic authentication document |

Publications in the root cover: EPUB direct acquisition with a progression service and an `authenticate`
hint; open-access EPUB; single-file MP3 audiobook with `duration`, narrators and a progression service;
Readium LCP through `indirectAcquisition`; a Readium audiobook package; buy with
`properties.price`; borrow with `properties.copies`, `properties.holds` and a bounded
`properties.availability`; subscribe. The unsupported and transactional publications stay in the feed —
Enve lists them as rejected content rather than dropping them.

### OPDS 1.2

| Endpoint | What it exercises |
| --- | --- |
| `GET /opds/v1/root.xml` | navigation feed that also carries one acquisition entry, plus the OpenSearch link |
| `GET /opds/v1/acquisition.xml` | `opds:price`, `opds:availability`, `opds:copies`, `opds:holds`, `opds:indirectAcquisition`, `schema:Series`, Adobe DRM, an audio acquisition, a progression service, `next`/`first`/`last` |
| `GET /opds/v1/acquisition-page2.xml` | `previous`/`first`/`last`, PDF and Unicode entries |
| `GET /opds/v1/entry/lab-ebook-101.xml` | a root `<entry>` document |
| `GET /opds/v1/opensearch.xml` | OpenSearch description; both `Url` templates are absolute and built from the request's `Host` |
| `GET /opds/v1/search.xml?q=…` | static Atom result set |
| `GET /opds/v1/protected.xml` | always 401 with an authentication document |

### Authentication

| Endpoint | What it exercises |
| --- | --- |
| `GET /opds/auth/basic.json` | `http://opds-spec.org/auth/basic` with labels, logo, help and start links |
| `GET /opds/auth/oauth-password.json` | `oauth/password` with `authenticate` and `refresh` links, plus a basic fallback flow |
| `GET /opds/auth/oauth-implicit.json` | `oauth/implicit` with `authenticate` (browser) and `refresh` links |
| `POST /opds/auth/oauth/token` | 200 token pair for a body naming `password` or `refresh_token`, 400 `unsupported_grant_type` otherwise |
| `GET /opds/auth/oauth/authorize?redirect_uri=…&state=…` | 302 back to the supplied `redirect_uri` with `#access_token=…&token_type=Bearer&expires_in=3600&state=…`; 400 when `redirect_uri` is missing |
| `GET /opds/auth/help.html`, `GET /opds/auth/register.html` | the pages the documents link to |

The tokens are fixed placeholder strings. No real credential is stored anywhere in the fixture; the 401
endpoints answer 401 unconditionally and the gated feed accepts any non-empty `Authorization` header, so a
tester can prove the app sends credentials without the fixture knowing one.

### OPDS Progression 1.0 (draft)

All five services are advertised from feed entries with `rel="http://opds-spec.org/progression"` and
`type="application/opds-progression+json"`, which is what Enve's auto-discovery requires.

| Endpoint | Method | Response |
| --- | --- | --- |
| `/opds/progression/lab-ebook-001` | `GET` before any write | 200 with an empty payload — never recorded |
| `/opds/progression/lab-ebook-001` | `PUT` (valid) before any write | 201 with the submitted document echoed back |
| `/opds/progression/lab-ebook-001` | `GET` after a write | 200 with a document carrying a text directive, an element id and a CFI |
| `/opds/progression/lab-ebook-001` | `PUT` (valid) after a write | 200 with the submitted document echoed back |
| `/opds/progression/lab-ebook-001` | `PUT` (invalid) | 400 `progression-invalid-payload` |
| `/opds/progression/lab-ebook-101` | `GET`, `PUT` | 200; the document's references include one Enve cannot resolve, which must survive a round trip |
| `/opds/progression/lab-audiobook-001` | `GET`, `PUT` | 200; `#t=1350.5` against the feed's `duration: 7200` is `progression: 0.1875` |
| `/opds/progression/lab-conflict-001` | `PUT` | 409 `progression-date` as `application/problem+json` |
| `/opds/progression/lab-conflict-001` | `GET` | 200 with a point newer than the fixture's other documents |
| `/opds/progression/lab-malformed-001` | `GET` | 200, correct media type, a body that fails the schema |
| `/opds/progression/lab-malformed-001` | `PUT` | 200 with an empty body, which the draft forbids |
| `/opds/progression/lab-protected-001` | any | 401 with an authentication document |
| `/opds/progression/progression.schema.json` | `GET` | the shape the fixture validates against |

A valid `PUT` must carry `Content-Type: application/opds-progression+json` and a body with `modified` as an
ISO 8601 date and time, a URI-shaped `device.id`, a non-empty `device.name` and a `progression` inside
`0…1`. Anything else falls through to the 400. That is as far as WireMock's matchers reach: they are four
`matchesJsonPath` regexes, not a JSON Schema validation. The published schema is there for a stricter
external check.

`lab-ebook-001` is the only stateful endpoint. It uses the WireMock scenario
`opds-progression-lab-ebook-001`, `Started` → `Recorded`, and `GET` changes with the state. Reset it with:

```bash
curl -sS -X PUT -H 'Content-Type: application/json' --data '{"state":"Started"}' \
  http://127.0.0.1:9091/__admin/scenarios/opds-progression-lab-ebook-001/state
```

Do not use `POST /__admin/scenarios/reset` — it resets every scenario in the lab's WireMock, including
fixtures this one does not own.

### Malformed and credential-leak targets

| Endpoint | Response |
| --- | --- |
| `GET /opds/malformed/html-as-feed`, `GET /opds/malformed/login-page.html` | 200 `text/html` sign-in page |
| `GET /opds/malformed/not-a-feed.json` | 200 `application/opds+json` with JSON that is not a feed |
| `GET /opds/malformed/truncated.json` | 200 with JSON that stops mid-object |
| `GET /opds/malformed/truncated-atom.xml` | 200 `application/atom+xml` with XML that stops mid-element |
| `GET /opds/malformed/html-declared-atom.xml` | 200 `application/atom+xml` with an HTML body |
| `GET /opds/redirect/cross-origin/epub` | 302 to `/opds/echo/headers` on a different origin, chosen from the request's `Host` |
| `GET /opds/redirect/same-origin/epub` | 302 to `/opds/files/lab-ebook-001.epub` |
| `GET /opds/echo/headers` | 200 JSON reporting **whether** `Authorization`, `Proxy-Authorization`, `Cookie`, `X-Enve-Token`, `X-Auth-Token` and `X-Api-Key` arrived, never their values |

Cross-origin targets by request host: `10.0.0.116` → `100.114.100.51:9091`, `100.114.100.51` →
`10.0.0.116:9091`, `localhost` → `127.0.0.1:9091`, anything else → `localhost:9091`. The client under test
has to be able to reach both addresses for the hop to complete; a client that can only reach one of them
still proves the interesting half, because the request that leaves for the second origin is the one whose
headers matter.

## Pointing Enve at the fixture

| Connection URL | Exercises |
| --- | --- |
| `http://10.0.0.116:9091/opds/v2/root.json` | the OPDS 2.0 catalog, its sub-feeds and the progression services |
| `http://10.0.0.116:9091/opds/v1/root.xml` | the OPDS 1.2 catalog |
| `http://10.0.0.116:9091/opds/v2/protected.json` | the unauthorized path at connection time |
| `http://10.0.0.116:9091/opds/malformed/html-as-feed` | a URL that answers 200 with a sign-in page |
| `http://10.0.0.116:9091/opds/malformed/not-a-feed.json` | JSON that is not an OPDS document |

Substitute `100.114.100.51` for the Tailscale run. Importing the OPDS 2.0 root visits the root, its four
sub-feeds, the group collection, the partner catalog and page 2 — eight requests, all of which must succeed
for the snapshot to count as complete. Facet targets are not followed, and the 401 and malformed endpoints
are deliberately not linked from any feed, so a normal import never turns partial.

## Verification

```bash
bin/verify-opds-fixture.sh http://10.0.0.116:9091
bin/verify-opds-fixture.sh http://10.0.0.116:9091 --with-binaries
```

With no argument the script uses `$OPDS_FIXTURE_BASE_URL`, then `http://127.0.0.1:9091`. It needs `curl`
and `jq`, holds every request to a 5 second connect and 15 second total timeout, prints one line per check,
and exits non-zero if any check failed. It checks status codes, content types and response shapes — feed
link relations, group and facet structure, acquisition properties, authentication document flows, the
progression status and payload contract, the redirect targets and the header-presence echo.

It sends no credentials. Its only writes are `PUT`s to the fixture's own progression endpoints; it sets the
scenario to `Started` before those writes and restores it afterwards, and it never touches WireMock state
outside that one scenario. Pass `--keep-scenario` to leave the endpoint in its post-write state for a
follow-up app test.

## Limitations

- **No byte ranges.** WireMock answers a `Range` request with the whole body and status 200, so the audio
  stubs advertise `Accept-Ranges: none`. Playback start is testable; seeking and scrubbing are not. Use
  Audiobookshelf, Jellyfin or WebDAV in the lab for real streaming behaviour.
- **The progression service does not store anything.** A `PUT` is echoed back, and the `GET` that follows it
  returns a fixed document rather than the one that was written. The document a write returns and the
  document the next read returns therefore disagree by design.
- **Only `lab-ebook-001` is stateful.** The other progression endpoints answer the same way every time, so
  two devices cannot be made to race against each other here.
- **Request matching is not schema validation.** The `PUT` guards are four `matchesJsonPath` regexes. A
  number in scientific notation with a positive exponent, or an unusual date offset format, would be
  rejected as invalid even though it is well formed. WireMock 3 adds `matchesJsonSchema`, which would
  replace all four; it is deliberately not used here because it fails to load on WireMock 2.
- **Response templating is required** for the OpenSearch description, the OAuth authorize redirect, the
  header echo and the progression `PUT` echoes. Those four stubs declare `"transformers":
  ["response-template"]`, which needs no WireMock command-line flag, but it does need a WireMock new enough
  to ship the extension. The verification script fails the OpenSearch check if templating did not run.
- **Search is static.** Both search endpoints ignore the query and return a fixed result set.
- **The cross-origin redirect needs two reachable addresses** to complete end to end from the app; see the
  table above.
- **The OAuth authorize endpoint reflects `redirect_uri` verbatim.** That is an open redirect, acceptable
  only because this is an isolated test lab. Keep the callback scheme aligned with the app build under test.
- **The LCP licence and Adobe fulfilment token are stubs**, enough to be recognised by media type and
  refused. They are not valid licences and no fulfilment happens.
- **The lab is not a conformance suite.** The fixture is shaped against OPDS 2.0, OPDS 1.2, OPDS
  Authentication 1.0 and the OPDS Progression 1.0 draft as Enve reads them. The progression draft is not
  ratified and its registry error identifiers are provisional.
