# OPDS Authentication

Enve implements [OPDS Authentication 1.0](https://drafts.opds.io/authentication-for-opds-1.0). A catalog
that needs no sign-in is unaffected: nothing here runs until a server asks.

## Discovery

An Authentication Document reaches Enve three ways, in this order:

1. **The body of a `401`**, when it declares `application/opds-authentication+json` or the legacy
   `application/vnd.opds.authentication.v1.0+json`.
2. **A `WWW-Authenticate` challenge** naming one with an `href` parameter.
3. **A link in the feed** — `rel="http://opds-spec.org/auth/document"`, any link typed as an
   authentication document, or a `properties.authenticate` hint on one of the feed's own links. A hint on a
   publication's progression link counts too, but only when that service sits on the catalog's own origin:
   a service the catalog delegated elsewhere authenticates on its own terms and says nothing about the
   connection. `OPDSProvider` remembers whichever it finds as the connection's `documentURL` — during a
   catalog import and while browsing — so a later `401` has somewhere to point even when the server answers
   it with an HTML page.

A `401` body is just as often a sign-in web page, so `OPDSAuthenticationDocument.decode` returns `nil` for
anything that is not the real thing. That is the difference between telling the reader how to sign in and
telling them the connection is broken.

All three routes are gated to the **configured feed's own origin**. A `401` from a host the feed merely
nominated — a progression service, a mirror an acquisition redirected to — is not recorded as this
connection's challenge, and `fetchAuthenticationDocument` refuses a document off that origin outright.
Without that gate a catalog would choose the host Enve renders a password field for.

A document that names itself with a `self` link carries that address; one that does not takes the URL it
was fetched from. Either way the address is remembered on the connection and **merged** rather than
replaced by a later sign-in, so a flow that does not repeat it does not lose it.

The `WWW-Authenticate` reader splits on quoting rather than on commas. A realm is free text and routinely
contains a comma, and a server may send several challenges in one header; splitting naively tears the realm
in half and takes the rest of it for the document's address.

`properties.authenticate` on a progression link is the same mechanism scoped to one service; see
[OPDS Progression](opds-progression.md).

## Flows

| `type` | Enve | What happens |
|---|---|---|
| `…/auth/basic` | ✓ | The login and password go on the connection, where every other Enve credential lives. `OPDSSessionDelegate` answers the challenge, and `applyCredentials` also writes the header out for the paths that never see one. |
| `…/auth/digest` | ✓ | The same. `URLSession` computes the digest from the connection's login and password. |
| `…/auth/local` | ✓ | The credentials are posted to the `authenticate` link with no `grant_type`; the server checks them itself and returns a token. |
| `…/auth/oauth/password` | ✓ | `grant_type=password` to the `authenticate` link. |
| `…/auth/oauth/implicit` | ✓ | `ASWebAuthenticationSession` on the `authenticate` link with `response_type=token`. |
| anything else | listed, not offered | A SAML or vendor flow is shown by name so the reader knows what the catalog wants, rather than being given an empty sheet. |

A flow that names no `authenticate` link cannot be run whatever its type says, so it is listed and not
offered.

Every authentication object the document carries is kept. A catalog that offers OAuth *and* Basic gives the
reader both, which matters when one of them is misconfigured.

### The implicit flow

`client_id` is `http://opds-spec.org/auth/client` — the identifier the specification requires every OPDS
client to present — unless the catalog already put one on the authorize URL, in which case it is left
alone: overwriting it would sign the reader in as somebody else.

The redirect URI is `enve-book://opds-auth/`, with the trailing slash the specification registers. The
token comes back in the redirect's fragment; a server that puts it in the query instead is still
understood, because several do. A `state` nonce is generated per attempt and a callback that does not
return it — or returns a different one — is refused. A nonce that cannot be drawn stops the flow rather
than being replaced by a guessable value.

The system may deliver that redirect by **relaunching Enve** rather than through the in-app browser sheet,
so `AppRootView`'s URL handler gives `OPDSAuthenticationService.handleCallback` first refusal on any
`enve-book://opds-auth/` URL before the reader and player links are considered.

## Tokens

| Where | What |
|---|---|
| Keychain, through `SecureTokenStorage` under `opds-<connection id>` | the access token, the refresh token, and when it expires |
| `UserDefaults`, through `OPDSAuthenticationStore` | the adopted flow type, the `authenticate` and `refresh` URLs, the document URL, and the login the reader signed in as |
| memory only | the Authentication Document a `401` most recently produced |

The endpoints are not secrets and a refresh has to work on a cold launch, so they are kept where they can
be read without unlocking anything. The token never is. Nothing here is logged.

An **expired** token is withheld rather than sent: `authorizationHeaderValue` returns `nil` for it, the
refresh runs, and the retry carries the new one. Sending a token Enve already knew was stale turns a
refusal the reader could act on into one they cannot.

`OPDSProvider.send` is where this happens. Every OPDS request goes through it; a `401` on the feed's own
origin triggers one refresh and one retry, and a second `401` records the challenge for the sources screen.
One refresh runs per connection at a time, so a sync pass and a catalog load cannot race for the token.

A refresh that fails clears the token: the reader is asked to sign in again rather than left with a
connection that quietly does nothing.

## Where a credential may travel

A token exchange and a refresh carry the reader's password, or the refresh token standing in for it, **in
the request body**, so they do not run on a shared session. `OPDSCredentialTransport` scopes one to the
endpoint:

- The endpoint must be `https`, on the feed's own origin, or on the local network — the case the app's
  arbitrary-loads exception exists for. Anything else is refused before the request is built.
- A redirect that leaves the endpoint's own origin is **not followed at all**. `URLSession` replays the body
  across a `307` or a `308`, and there is no header to strip when the secret is the payload.
- A downgrade out of `https`, a scheme Enve does not speak, and a URL carrying its own userinfo are refused
  by `HTTPRedirectPolicy` on the way.
- Local self-signed TLS and mTLS identities are still answered, so a LAN catalog and its identity provider
  stay reachable.

## Signing out

`OPDSAuthenticationStore.signOut` forgets the token and the adopted flow; the browser's `signOut` also
clears the login and password a Basic flow put on the connection itself, and reads the catalog again — which
is what re-offers the sign-in when the server still wants one. What the catalog said about *how* to sign in
is kept: it is a description rather than a credential, and without it the reader has to provoke another
`401` before they can sign back in.

## Lifetime

A connection that goes away takes its sign-in with it. `OPDSAuthenticationStore.retainConnections` runs
beside the progression endpoint store in `LibraryRecoveryCoordinator.pruneDisconnectedProviderData`, and
both are cleared by a full data reset.

## Where the code lives

| Path | Responsibility |
|---|---|
| `enve/Services/OPDS/OPDSAuthenticationDocument.swift` | The document, its flows, and the `WWW-Authenticate` reader |
| `enve/Services/OPDS/OPDSAuthenticationService.swift` | The flows, the browser session, the token exchange and refresh |
| `enve/Services/OPDS/OPDSAuthenticationStore.swift` | What a connection signed in with, and the token |
| `enve/Services/OPDS/OPDSCredentialTransport.swift` | The scoped session a credential exchange runs on |
| `enve/Screens/Sources/OPDSSignInSheet.swift` | The sign-in surface |
| `enve/Networking/Providers/OPDSProvider.swift` | `401` handling, retry, and where credentials may travel |
