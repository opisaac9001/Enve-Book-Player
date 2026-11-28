# book club: by Enve

A self-hosted reading club with a browser client and a documented HTTP API. A single instance serves members on their own devices. It stores membership, reading plans, opted-in progress, chapter discussions, notes, nominations, votes, and any book copies the host chooses to share. Members can also bring their own copy.

See the [product roadmap](ROADMAP.md) for comparisons and planned features.

## Run it in a homelab

From `BookClubsServer`, run:

```sh
docker compose up --build -d
```

Open [http://localhost:8794](http://localhost:8794). The browser walks the first host through profile creation, saving a recovery key, creating a club, and inviting members. A new install binds to loopback. To reach it from another device, put the instance behind an HTTPS reverse proxy or set `BOOK_CLUB_BIND` to the address of your private network interface. The browser builds invitation links from the address you are using, so generate them from the address your members can reach.

SQLite lives in the Compose `data` volume. Back up the volume with the service stopped, or use SQLite's online backup mechanism. Keep the database, its WAL, and its shared-memory file together if copying a stopped filesystem. Keep backups private because the operator can read data stored by the service, including private notes.

For a direct install with Node 24 or newer, run `npm start`. Set `BOOK_CLUB_DATABASE` to choose the SQLite file, `BOOK_CLUB_HOST` to choose the listen address, and `BOOK_CLUB_PORT` to change the port. The default database is `./data/book-club.sqlite`. The service applies migrations on startup. Node runs this service without installing npm dependencies.

### Catalog plugins

Copy `config/catalogs.example.json` to `config/catalogs.json`, keep the entries you want, and replace the example addresses. Set `BOOK_CLUB_CATALOG_CONFIG=/config/catalogs.json` in your Compose `.env` or shell, or point at the local file for Node. Put the referenced credential variables in `config/catalog.env` for Compose or the Node process environment. Use credentials specific to the read-only libraries you intend to share. Provider addresses must be reachable from the service, including from inside its container.

| Plugin | Configuration | Capabilities |
| --- | --- | --- |
| OPDS | `type: "opds"`, URL of an OPDS 1 Atom or OPDS 2 JSON catalog | Navigate feeds, page through titles, and search when the catalog advertises search. Without a search endpoint, search filters the current feed page. [OPDS specifications](https://specs.opds.io/) |
| Grimmory | `type: "grimmory"`, Grimmory base URL, `usernameEnv` and `passwordEnv` for a Grimmory OPDS user | Browse and search Grimmory's OPDS catalog. Enable OPDS in Grimmory and restrict the OPDS user's library permissions. [Grimmory OPDS setup](https://grimmory.org/docs/integration/opds/) |
| Audiobookshelf | `type: "audiobookshelf"`, Audiobookshelf base URL, `libraryId` for a books library, and `tokenEnv` for an API key | Browse and search the configured library using the permissions of that key. [Audiobookshelf API keys](https://audiobookshelf.org/docs/documentation/server-management/api-keys/) |
| HTTP plugin | `type: "book-club"`, the adapter endpoint URL and an optional bearer token or Basic credentials | Bring catalogs from another service using the [catalog adapter contract](protocol/BOOK-CLUB.md). |

Catalogs are instance-wide. Signed-in people who belong to a club can browse the configured metadata and nominate titles from it. The service has open profile signup, so configure only libraries whose catalog metadata you intend to share with accounts on the instance. Source credentials, media URLs, cover URLs, and upstream identifiers stay on the homelab side of the connection.

### Host a copy for a reading

1. Set "shareFiles": true in the entries of your catalog configuration that the operator allows club hosts to use for file sharing. The example config starts with file sharing off. Use catalogs and books you have permission to share.
2. As the club host, open **Catalogs** in the browser, find the edition, and choose **Host ebook for current reading** or **Host audiobook for current reading**. You can also choose the copy while starting a new catalog reading.
3. Members can download from **Club copy**. Enve for iOS imports and links the copy using **Download Club Copy**. The browser downloads individual files, and the audiobook manifest gives compatible clients the track order.

The server imports the bytes once and keeps them beside the SQLite file in a directory ending in .hosted-books, including inside the Compose data volume. The data volume backup includes both the database and hosted files. Downloads work while the original catalog is offline. The host can remove access or publish a replacement. Copies stay available on archived readings until the host removes them or deletes the club, and previously saved downloads remain on members’ devices.

OPDS and Grimmory support direct same-origin EPUB, PDF, MP3, M4A and M4B acquisition files. Audiobookshelf uses its download permission and can import ordered multipart MP3/M4A/M4B audiobooks or a primary EPUB/PDF. Purchased, borrowed, indirect, and sample OPDS acquisition links are excluded. Set BOOK_CLUB_COPY_MAX_BYTES to override the 4 GiB per-edition limit. The SQLite reference runtime provides file hosting on one homelab instance.

### Connect another app or service

Start with [the protocol draft](protocol/BOOK-CLUB.md) and [OpenAPI document](protocol/openapi.json). An instance publishes its capabilities at `/v1/discovery` and its API description at `/openapi.json`. An independent client can create or restore profiles, join clubs, check in, publish progress with member consent, and read or write discussions and notes via the same API. The existing native Enve clients can use a compatible instance through their configured service URL. This checkout includes a browser client that works with any instance address directly.

To allow a separately hosted browser client, set `BOOK_CLUB_WEB_ORIGINS` to a comma-separated list of its exact origins, such as `https://reader.example.net`. The bundled client uses the same origin as the API and needs no CORS setting.

## Develop the Worker and native clients

The Cloudflare runtime remains available. From `BookClubsServer`:

```sh
npm ci
npm run migrate
npm run dev
```

The local Worker listens on `http://127.0.0.1:8794`. Run `npm test` in a second terminal for HTTP tests against the Worker plus the self-hosted implementation. Run `npm run test:homelab` for the self-contained SQLite and catalog integration suite. The iOS debug app accepts `ENVE_CLUBS_SERVICE_URL=http://127.0.0.1:8794` in the simulator environment. In Xcode, set it under Run → Arguments → Environment Variables. Find Book Clubs in the Library’s More menu. Hearth shows a Book Club Books row when you belong to a club with an active read.

For the two-account iOS flow, set `TEST_RUNNER_ENVE_CLUBS_UI_TEST_URL=http://127.0.0.1:8794`, select the `UISmokeTests` plan, and run `enveUITests/BookClubsUITests` on an iPhone Air simulator. The test seeds a host and real invite through the Worker and uses the app as a second member.

For Android, build the debug app with `./gradlew :app:assembleDebug -PenveClubsServiceURL=http://127.0.0.1:8794` from the Android repository. Run `adb reverse tcp:8794 tcp:8794` for the test device, then install the debug APK. Book Clubs opens from the Library menu or an `enve-book://club/join?code=…` invitation. Both apps use the same accounts, memberships, invites, and reading plans.

## Optional Cloudflare hosting

1. Create a dedicated D1 database and an HTTPS hostname for the Worker. Copy `wrangler.jsonc` to the ignored `wrangler.production.jsonc`, replace the local binding’s database name and ID, and configure the Worker route. Keep separate bindings and hosts for staging and production.
2. Apply `npx wrangler d1 migrations apply DB --remote --config wrangler.production.jsonc` against that database. Configure the `CLUB_MODERATOR_TOKEN` secret and the comma-separated `CLUB_BLOCKED_WORDS` with the maintained moderation list. Deploy with the production config after checking the target account and database. `GET /v1/health` verifies the Worker is reachable.
3. Set the Xcode build setting `ENVE_CLUBS_SERVICE_URL` to the HTTPS origin. For Android, set the `enveClubsServiceURL` Gradle property to the same HTTPS origin. An unset URL hides Clubs in either build. Host `books/clubs/join/` and its local JavaScript from the Enve website so recipients can tap an invite in Messages or another app. The invite code travels in the URL fragment, and the page opens it through Enve’s existing custom URL scheme.
4. Publish accurate privacy and support information for club data, verify recovery and deletion, and assign a person to check and resolve reports before offering discussion to users. The Worker exposes open reports to the moderator token at `GET /v1/moderation` and resolves a report with `POST /v1/moderation/{id}` and `{ "removePost": true }` or `false`. Use an operator-only HTTP client and keep that credential out of app builds and logs.

Accounts authenticate with bearer sessions and a separate printable recovery key. Only hashes are stored. A new invite replaces the active invite, expires after seven days, and can be revoked by the host. The API accepts milliseconds since the Unix epoch for timestamps and versions progress sharing by read, member, and a new epoch when the sharing settings change.

`POST /v1/clubs/join` accepts a `code` and an optional `name` for that club. Omitting `name` keeps an existing club display name or uses the member’s Clubs profile name.
