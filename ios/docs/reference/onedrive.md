# OneDrive

Enve integrates OneDrive as a read-only library provider through Microsoft Graph. A user signs in, browses their drive, selects one or more folders, and imports supported audiobook and ebook files. Audio can stream or download; ebooks download into Enve's local reader cache. Enve never edits or deletes files in OneDrive.

## Microsoft Entra app registration

Create a Microsoft Entra app registration for the Enve build you distribute:

1. Allow both organizational accounts and personal Microsoft accounts.
2. Add an iOS/macOS platform with bundle identifier `com.enve.enve` and redirect URI `msauth.com.enve.enve://auth`.
3. Enable public-client authorization-code flow with PKCE. Do not create or embed a client secret.
4. Add the delegated Microsoft Graph permission `Files.Read`. Enve also requests `openid`, `profile`, and `offline_access` for identity and token refresh.
5. Copy `enve/Configuration/DeveloperSettings.example.plist` to the ignored `DeveloperSettings.plist` and set `OneDriveClientID` to the application (client) ID.

Use your own bundle identifier and matching `msauth.<bundle-id>://auth` redirect URI when shipping a fork. Update both the OneDrive OAuth configuration and the URL type in `Info.plist` together.

## Catalog behavior

- Every selected folder is an Enve library.
- A folder containing supported audio files becomes one audiobook; nested folders are scanned recursively.
- Supported standalone ebook files become ebook entries.
- Microsoft Graph pagination is followed until the selected trees are complete.
- A refresh performs a complete snapshot reconciliation. Enve does not advertise delta import because Graph deletions cannot be represented safely by Enve's current delta contract.
- Graph pre-authenticated download URLs are short-lived. Enve obtains a fresh item record before playback or download and does not send the Microsoft bearer token to the download host.
- OneDrive does not store Enve playback or reading progress. Progress remains local and participates in Enve's normal iCloud progress sync when enabled.

Deleting a OneDrive source removes its OAuth credentials from the Keychain. Re-authentication and folder selection remain available from the source detail screen.
