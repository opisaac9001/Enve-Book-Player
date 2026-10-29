# Google Drive production review

This guide records the integration's permission rationale and verification requirements. Each distributor must register its own native OAuth client, configure its public homepage and privacy policy, and complete the applicable Google review. Keep account administration, submission correspondence, and private recording links outside the source repository.

## Permission justification

Requested scope: `https://www.googleapis.com/auth/drive.readonly`.

Enve Book Player is an audiobook and ebook reader. Users connect their own Google Drive, browse existing folders or search filenames, select supported book files, and import them into their device's local library for reading and listening. The app lists file metadata and downloads only selected files. It never creates, changes, or deletes Drive files.

The existing native folder browser needs access to books and folders that users created before connecting Enve. `drive.file` does not provide this account-wide browsing behavior. A Google Picker implementation would permit a narrower scope, but would be a different selection flow; it is not the implementation being submitted. Google must still accept the need for the broader scope and the permitted application type.

## Data flow for reviewers

1. The device opens Google's system authentication session and requests authorization using the native OAuth client with PKCE.
2. The device exchanges the authorization code directly with Google's token endpoint. Tokens are held in the current app profile's Keychain.
3. The native browser calls the Drive API directly over HTTPS to list/search file IDs, names, MIME types, sizes, modification times, and folder relationships.
4. Selected files download directly from Google to temporary storage on the device, then enter the normal local-book importer. Temporary staging is removed after completion or failure.
5. The local reader/player opens the imported files. There is no Enve-operated OAuth broker, file proxy, or cloud file store in this flow.
6. Disconnect removes the current profile's saved tokens. Users may revoke the Google grant from Google Account connections. Local imports remain until removed from the library.

The audit confirmed that `CloudProgressEligibility.includes` accepts `.local` books and `CloudKitProgressSync` writes title/author and progress records when iCloud sync is enabled. Drive imports become `.local` items. This optional path therefore needs to be disclosed in the assessment questionnaire; a device-only claim for all Google-derived information would be inaccurate. Other sync/export paths still need review. The public policy explicitly discloses these separately enabled features. Google decides whether the complete application qualifies for an assessment exemption; do not claim CASA exemption has been granted.

## Review demonstration

Use developer-owned sample books and hide unrelated files and notifications. Pause recording for passwords and verification codes.

1. Show the app's public homepage and privacy policy.
2. Connect Google Drive from Add a source and show the permission explanation.
3. Complete native Google authorization without exposing tokens or authorization codes.
4. Browse a demo folder, search filenames, and import an EPUB and audio sample.
5. Open both local imports and demonstrate disconnect, grant revocation, and local-file removal.

Submit the reviewed demonstration through Google's verification process. Keep its private evidence and account ownership records out of public documentation.

## Release gates

- Verify domain ownership and save the correct app branding, public policy links, and authorized domain.
- Declare the implemented `drive.readonly` scope and finish reviewing optional sync/export disclosures.
- Complete Google's follow-up and any required assessment before claiming approval.
- Test production sign-in with an account outside the developer tester list.
- Verify network-disabled playback and local import retention after disconnect.

The last recorded local verification passed the iPhone Air build, 1,639 app tests with 35 skips, and 11 cloud regression checks. It exercised consent, listing, search, sample imports, local rendering/playback, and saved-connection restoration. Those results do not establish public non-tester access, production approval, or an assessment exemption.

Moving an OAuth audience to Production and passing scope verification are separate milestones. Confirm the current review status in Google Cloud before release; do not infer approval from successful developer sign-in.

## Google references

- https://developers.google.com/workspace/drive/api/guides/api-specific-auth
- https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification
- https://support.google.com/cloud/answer/13461325
- https://developers.google.com/terms/api-services-user-data-policy
