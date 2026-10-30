# Google Drive and Dropbox imports

Google Drive and Dropbox appear under **Settings → Add a source → Browse all sources → Cloud drives**. Sign in, open a folder or search for a book, select files, and choose **Import**. Enve downloads those files and adds them to the local library for offline reading or listening. Signing in alone does not import the entire drive.

The first release imports individual files rather than maintaining a mirrored cloud library. Files remain in Enve after disconnecting the cloud account. Cloud files are never modified or deleted, and reading/listening progress is not written to Google Drive or Dropbox. Direct cloud playback and automatic folder refresh are not part of this import flow.

Supported files use Enve's existing audiobook and ebook formats, including M4B, MP3, EPUB, PDF, and book ZIP archives. Select the tracks of a multi-file audiobook from the same folder and enable **Combine selected audio tracks into one book**. Files from different folders remain separate. Search results exclude unsupported files.

## Developer setup

Copy `enve/Configuration/DeveloperSettings.example.plist` to the ignored `DeveloperSettings.plist`. Keep OAuth client identifiers there and credentials in Keychain. Neither integration uses an embedded client secret.

### Google Drive

1. Use a developer-owned Google Cloud project with the Drive API enabled.
2. Register an iOS OAuth client for your app's bundle identifier and set `GoogleDriveClientID`.
3. The callback uses the reversed client ID scheme followed by `:/oauth/google`. For example, `123-example.apps.googleusercontent.com` becomes `com.googleusercontent.apps.123-example:/oauth/google`.
4. Configure the consent screen and its test users or production verification separately from Enve Family's Calendar integration.
5. This native folder browser requests `drive.readonly`, a restricted scope that allows listing and downloading existing files. It does not request write permission. Google's public-app verification requirements apply. Do not add this scope to Enve Family's pending Calendar review.

Google recommends its Picker API with `drive.file` when per-file selection is sufficient. That would require a separate picker-based flow; the current native browser needs access to existing folders and files. An alternative available today is importing through iOS Files with Google Drive installed, which does not require Enve's own Drive OAuth configuration.

### Dropbox

1. Create a scoped Dropbox application. Select Full Dropbox access if users must browse their existing book folders; App Folder access exposes only that app's folder.
2. Enable `files.metadata.read` and `files.content.read`.
3. Register the redirect URI `<OAuthRedirectScheme>:/oauth/dropbox`; the default is `com.enve.enve:/oauth/dropbox`.
4. Set `DropboxAppKey` and, if necessary, `OAuthRedirectScheme` in the ignored developer settings.
5. The authorization-code flow uses PKCE and `token_access_type=offline`. Access and refresh tokens stay in the current Enve profile's Keychain storage. Dropbox app approval and production user limits are managed in the developer console.

## Production approval

See [Google Drive production review](google-drive-production-review.md) for the current Google project status, data-flow disclosure, scope justification, video script, and remaining release gates. Production audience status does not mean Google has approved the requested scope.

## Verification

On October 22, 2026, the iPhone Air simulator build and AllTests plan passed: 1,639 tests passed, 35 skipped, and no failures. All 11 cloud-drive regression checks passed. An existing CloudKit Sendable warning remains outside this change. The real Dropbox and Google sign-in pages opened in a separate provider test simulator; cancelling Dropbox returned to the connection screen without a false connected state. Google Drive was also verified with real account consent, file listing, search, download, and import of an original sample EPUB and five-second WAV. The imported EPUB rendered in the reader and the WAV played to completion from local storage. Reopening the app restored the saved Google connection; a second import verified that Done returns to Settings. Network-disabled playback and real Dropbox account imports remain to be verified. The Book Player Google project moved to Production on October 22, 2026. Restricted-scope verification was submitted on October 22, 2026, and Google confirms data access is under review; the unverified warning and user cap remain. Existing expired Testing grants require sign-in again. Production preparation is tracked in [the review checklist](google-drive-production-review.md).

Automated fixture tests cover folder pagination, book filtering, Google query escaping, expired-token renewal, refresh-token retention, profile credential isolation, and local import staging. These tests do not establish that a developer application is correctly registered or approved. Each provider must also be tested with a real account: sign in, browse, search, import an audiobook and ebook, open them offline, reconnect, and disconnect.

## References

- [Google Drive permissions and verification](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)
- [Google native OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)
- [Dropbox OAuth guide](https://developers.dropbox.com/oauth-guide)
- [Dropbox offline access](https://dropbox.tech/developers/using-oauth-2-0-with-offline-access)
