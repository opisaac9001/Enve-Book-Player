# OIDC, SSO, and Browser Sign-In

This guide covers authentication for every service supported by Enve. It combines each service's current documentation with the authentication paths exposed by the iOS and Android apps. The audit was last completed on August 26, 2026.

Three different URLs are easy to confuse:

- A **server callback** returns the identity provider to Audiobookshelf, Grimmory, Komga, Storyteller, BookOrbit, or another server.
- An **Enve callback** returns a completed mobile authorization flow to Enve.
- A **browser login** can use OIDC behind the scenes without exposing a separate Enve callback to the identity provider.

Redirect URIs must match exactly. Scheme, hostname, port, path, capitalization, and trailing slash all matter.

## Supported-service audit

| Service | OIDC or browser SSO through Enve | Enve sign-in path |
| --- | --- | --- |
| Audiobookshelf | Yes | Username/password or Audiobookshelf OIDC |
| Grimmory | Yes | Username/password, token, or Grimmory OIDC |
| BookOrbit | Yes | Username/password or BookOrbit OIDC |
| Komga | Yes | Username/password, API key, or Komga OAuth2/OIDC web session |
| Storyteller | Yes | Username/password or Storyteller browser login; configured OAuth/OIDC providers work inside that login |
| Kavita | No | Username/password or authentication key; Kavita supports OIDC, but Enve does not currently implement its OIDC session flow |
| Jellyfin | No direct OIDC | Username/password or Quick Connect; the third-party Jellyfin SSO plugin is not an Enve login method |
| Plex | Not standard OIDC | Plex PIN authentication or a manual Plex token |
| Emby | No | Username/password |
| Silo | No | Username/password or access token/API key |
| OPDS | No generic OIDC flow | Username/password, token, or an anonymous catalog when supported |
| WebDAV | No generic OIDC flow | Username/password, bearer token, service token, or custom headers |
| SMB | No | Username/password |
| TorBox | No | API token |
| Premiumize | No | Customer ID and API key/PIN over WebDAV |
| Real-Debrid | No | API token |
| Local files | Not applicable | Device file access |

Google Drive and Dropbox on iOS use developer-owned OAuth applications. They are separate from self-hosted server OIDC and are covered in [the iOS development guide](../../ios/DEVELOPMENT.md).

## Enve callback reference

| Service | iOS | Android | Register the Enve callback with |
| --- | --- | --- | --- |
| Audiobookshelf | `enveapp://oauth/abs` | `audiobookshelf://oauth` | Audiobookshelf's **Allowed Mobile Redirect URIs** |
| Grimmory | `booklore://oauth2-callback` by default; alternatives are listed below | `grimmory://oauth2-callback` | Grimmory's **Mobile Redirect URIs** and the identity provider's allowed redirects |
| BookOrbit | `<server-url>/oauth2-callback` | `<server-url>/oauth2-callback` | The identity provider's allowed redirects |
| Komga | No custom Enve callback | No custom Enve callback | Register Komga's HTTPS callback with the identity provider |
| Storyteller | `storyteller` URL scheme | `storyteller` URL scheme | Register Storyteller's displayed HTTPS callback with the identity provider, not the mobile scheme |

## Audiobookshelf

Audiobookshelf has two separate sets of redirect URIs: callbacks for Audiobookshelf itself and callbacks for third-party mobile apps such as Enve.

### Configure Audiobookshelf at the identity provider

Register Audiobookshelf's own callback URLs with the OIDC provider. For a root installation, the official values are:

```text
https://<your-server>/auth/openid/callback
https://<your-server>/auth/openid/mobile-redirect
```

For an installation served below `/audiobookshelf`, use:

```text
https://<your-server>/audiobookshelf/auth/openid/callback
https://<your-server>/audiobookshelf/auth/openid/mobile-redirect
```

The official Audiobookshelf guide recommends adding all four when the installation may be reached through both layouts.

### Allow Enve in Audiobookshelf

In Audiobookshelf, open **Settings > Authentication > OpenID Connect** and add the callback for each Enve platform to **Allowed Mobile Redirect URIs**:

```text
# iOS
enveapp://oauth/abs

# Android
audiobookshelf://oauth
```

Do not add these custom Enve callbacks to the identity provider. Audiobookshelf's documentation explicitly places third-party app callbacks in its own allowed-mobile list. Add both entries when iOS and Android connect to the same server. Enve requires an HTTPS Audiobookshelf URL for OIDC sign-in.

See the official [Audiobookshelf OIDC authentication guide](https://audiobookshelf.org/docs/documentation/server-management/oidc-authentication/).

## Grimmory

Grimmory has a normal web callback and a separate allowlist for native app callbacks.

### Configure Grimmory's web callback

Register Grimmory's standard callback with the identity provider:

```text
https://<your-grimmory-server>/oauth2-callback
```

Copy the exact value from Grimmory's **Provider Configuration Reference** panel. The official guide also lists the required scopes, PKCE method, logout URLs, and provider-specific setup.

### Allow Enve's mobile callback

Grimmory 3.1.0 and newer expose **Settings > OIDC > Mobile Redirect URIs**. Add the Enve callback there and to the same OIDC client's allowed redirect URI list at the identity provider.

Android uses Grimmory's official default mobile callback:

```text
grimmory://oauth2-callback
```

iOS currently defaults to the Booklore-compatible callback:

```text
booklore://oauth2-callback
```

The iOS connection form also offers:

```text
grimmory://oauth2-callback
enveapp://oauth/grimmory
```

The option selected in Enve must appear in both Grimmory's mobile allowlist and the identity provider's allowed redirects. New cross-platform configurations can select `grimmory://oauth2-callback` on iOS and use one mobile value for both platforms. Existing iOS installations may keep `booklore://oauth2-callback` for compatibility.

Update Grimmory if the **Mobile Redirect URIs** setting is unavailable. The setting was added in Grimmory 3.1.0.

See Grimmory's official [OIDC settings guide](https://grimmory.org/docs/authentication/oidc-settings/) and the [3.1.0 mobile redirect release change](https://github.com/grimmory-tools/grimmory/pull/1287).

## BookOrbit

BookOrbit uses a web callback derived from the server URL rather than a separate custom-scheme callback. Register this exact value with the identity provider:

```text
<server-url>/oauth2-callback
```

For example:

```text
https://books.example.com/oauth2-callback
```

If BookOrbit is served below a path, preserve it:

```text
https://example.com/bookorbit/oauth2-callback
```

The scheme, hostname, port, and path must match the BookOrbit URL entered in Enve. Use the externally reachable HTTPS address. When BookOrbit is behind a reverse proxy, ensure the proxy preserves the public host and scheme.

Do not register BookOrbit's internal API exchange endpoint, `/api/v1/auth/oidc/callback`, as the identity-provider redirect URI.

See the official [BookOrbit OIDC/SSO guide](https://bookorbit.app/oidc/).

## Komga

Komga supports both OAuth2 and OpenID Connect. The identity provider returns to Komga, not directly to Enve. Register this callback with the identity provider:

```text
<komga-base-url>/login/oauth2/code/<registration-id>
```

For example, a Keycloak registration named `keycloak` on `https://comics.example.com` uses:

```text
https://comics.example.com/login/oauth2/code/keycloak
```

Preserve Komga's configured base path when it has one. The registration ID must match the key used in Komga's OAuth client configuration.

Enve reads Komga's advertised providers, opens Komga's `/oauth2/authorization/<registration-id>` route, and retains the resulting `KOMGA-SESSION` cookie. There is no `enveapp://`, `enve://`, or other Enve callback to register for Komga. The same server-side configuration works for iOS and Android.

See Komga's official [social login guide](https://komga.org/docs/installation/oauth2/).

## Storyteller

Storyteller supports OAuth and OpenID Connect providers. Enve uses Storyteller's browser-based mobile login, so a Storyteller account backed only by OIDC can still sign in.

Set Storyteller's `AUTH_URL` to the public server origin followed by `/api/v2/auth`:

```text
AUTH_URL=https://storyteller.example.com/api/v2/auth
```

Create the provider in Storyteller, then copy the exact callback URL shown in Storyteller's authentication-provider settings into the identity provider. The callback depends on the provider name, so update it if that name changes.

Enve opens:

```text
<storyteller-server>/api/v2/token/app
```

Storyteller completes its own password or OAuth/OIDC login, then returns a short-lived app token through the `storyteller` URL scheme. Enve exchanges that token for a Storyteller session. Do not register the `storyteller` mobile scheme at the identity provider; register the HTTPS callback displayed by Storyteller.

See Storyteller's official [authentication-provider settings](https://storyteller-platform.dev/docs/settings/#authentication-providers).

## Services with upstream SSO that Enve does not use

### Kavita

Kavita has supported OpenID Connect since version 0.8.8. Its documented server callbacks are:

```text
https://<your-kavita-server>/signin-oidc
https://<your-kavita-server>/signout-callback-oidc
```

Enve does not currently complete Kavita's browser OIDC session flow. Use a Kavita username/password or authentication key in Enve. A Kavita deployment that disables every non-OIDC login method cannot currently be connected to Enve.

See Kavita's official [OpenID Connect guide](https://wiki.kavitareader.com/guides/admin-settings/open-id-connect/).

### Jellyfin

Jellyfin's core server supports username/password and Quick Connect. OIDC/SSO is available through a third-party plugin, but Enve does not implement that plugin's browser callback flow. Enve supports Jellyfin Quick Connect on both platforms, which can avoid entering the account password in Enve.

See Jellyfin's official [Quick Connect guide](https://jellyfin.org/docs/general/server/quick-connect/) and its [third-party plugin listing](https://jellyfin.org/docs/general/server/plugins/).

### Generic OPDS, WebDAV, and reverse-proxy SSO

An individual OPDS or WebDAV server may offer OAuth, or a reverse proxy may place OIDC in front of almost any service. Enve does not implement a generic browser OIDC exchange for those protocols. Use credentials, bearer tokens, service tokens, or custom headers supported by the specific connection. A browser-only forward-auth page is not itself an API authentication method.

## Other non-OIDC sign-in flows

- **Plex** uses Plex PIN authentication and polling. No custom Enve redirect needs to be registered with an identity provider.
- **Emby** uses username/password in Enve.
- **Silo** uses username/password or an access token/API key in Enve.
- **TorBox**, **Premiumize**, and **Real-Debrid** use their service credentials or API tokens.
- **SMB** uses share credentials.
- **Local files** require no server authentication.
- **Cloudflare Access** can be handled through Enve's browser session, service-token, or custom-header options where available. That protects the route separately from the library server's own login.

## Security and client configuration

Enve's direct server OIDC flows use the OAuth 2.0 authorization-code flow with PKCE where the service supports it. Enve does not embed a self-hosted OIDC client secret in either mobile app.

The server may still use a confidential client and keep a client secret on the server. Audiobookshelf, Grimmory, BookOrbit, Komga, and Storyteller each document their own supported client types. Do not copy a server-side secret into Enve or a mobile build.

- Use exact redirect URIs instead of wildcards where possible.
- Include the `openid` scope and the identity claims required by the server.
- Add `groups` only when group mapping is configured and supported by the provider.
- Keep the identity provider reachable from the server and the device browser.
- Keep client secrets, if the server uses them, in the server's protected configuration.

## Troubleshooting

### The identity provider reports `redirect_uri` mismatch

First identify which component owns the redirect:

- Audiobookshelf server login uses Audiobookshelf's HTTPS `/auth/openid/...` callbacks at the identity provider.
- Grimmory web login uses Grimmory's HTTPS `/oauth2-callback`; its mobile login also validates the selected Enve callback.
- BookOrbit uses `<server-url>/oauth2-callback` at the identity provider.
- Komga uses `<base-url>/login/oauth2/code/<registration-id>`.
- Storyteller displays the provider-specific HTTPS callback in its settings.
- Kavita uses `/signin-oidc`, but Kavita OIDC is not currently an Enve login method.

Then compare the full URI, including scheme, port, base path, registration or provider name, and trailing slash.

### Audiobookshelf reports `Invalid redirect_uri`

Add the platform-specific Enve callback to Audiobookshelf's **Allowed Mobile Redirect URIs**, save the authentication settings, and start a new sign-in. Do not add the Enve callback directly to the identity provider.

### Grimmory rejects or does not return from mobile sign-in

Confirm the selected callback is present in Grimmory's **Mobile Redirect URIs** and in the identity provider's client configuration. If the setting is missing, update to Grimmory 3.1.0 or newer.

### Komga completes SSO but Enve is still signed out

Confirm that the identity provider returned to Komga's HTTPS callback and that Komga created a `KOMGA-SESSION` cookie. Check the registration ID and Komga base path, then start a fresh SSO session from Enve.

### Storyteller does not offer the configured provider

Confirm `AUTH_URL` uses the externally reachable Storyteller origin plus `/api/v2/auth`. Verify the provider is enabled in Storyteller and that its displayed callback exactly matches the identity-provider configuration.

### Sign-in finishes but the browser does not return to Enve

Confirm the callback for the device's platform was registered. On iOS Grimmory connections, confirm that the option selected in Enve matches the registered URI. For Storyteller, confirm the server returned to the `storyteller` URL scheme. Start a new sign-in from Enve instead of reusing an older browser tab.

### Enve reports a missing or mismatched state

Cancel the flow and begin again from Enve. Do not reuse a callback URL from an earlier attempt. Check whether a proxy, login portal, or identity-provider rule removed the `state` query parameter.
