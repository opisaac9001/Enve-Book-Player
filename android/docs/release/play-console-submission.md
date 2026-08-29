# Google Play submission

Use this record for Enve Book Player 1.2 build 46. Recheck the answers against the signed production candidate before submitting them in Play Console.

## Privacy policy

- URL: https://envemedia.com/privacy-policy
- The same URL is used by the app, the Health Connect permission rationale, and the Play listing.

## Health apps declaration

- Health feature: **Sleep management**
- Health Connect permission: **Read sleep**
- Android permission: `android.permission.health.READ_SLEEP`
- Other health features: none
- Medical device or medical functionality: none

Permission justification:

> Enve Book Player optionally reads sleep sessions from Health Connect so the user can view sleep timing and stages alongside audiobook listening history. The app reads session start and end times, sleep stages, and source information for up to the previous 30 days. Processing occurs on the user's device. Enve does not write Health Connect data, upload it to an Enve server, share it with the developer or advertisers, or create a separate health-data database. The feature is optional and stops reading data when the user revokes permission.

The declaration requires current screenshots or video showing the sleep feature, its permission explanation, and the resulting user-facing view. Capture those from the signed candidate.

## Data safety draft

Google Play defines collection as transmitting user data off the device, including transmission by SDKs or to third-party servers. Local-only Health Connect processing is outside that definition. The app still has optional off-device flows when a user connects a server, uses Play Billing, enables a Google-managed model, downloads a model, or configures a remote AI endpoint.

Use **Yes** for collection until the final SDK and network review proves that every off-device flow falls outside the form. Use **No** for sharing where transfers are limited to a service the user deliberately configures or invokes and the user reasonably expects the transfer. Revisit that answer if the signed candidate contains any SDK transfer that does not meet Google's service-provider or user-initiated exceptions.

Candidate collected data types:

| Data type | Required | Purpose | Source |
|---|---|---|---|
| User IDs | Optional | App functionality and account management | User-configured media, sync, or AI services |
| Purchase history | Optional | Purchases | Google Play Billing tip jar |
| App interactions or other actions | Optional | App functionality | Playback progress and sync sent to a configured provider |
| Files and documents or other user-generated content | Optional | App functionality | Book context, annotations, or prompts sent only when the user configures a remote service |
| Device or other IDs | Optional | App functionality, fraud prevention, or SDK diagnostics | Google Play services, Billing, Cast, Wear, or on-device AI services if reported by their current SDK disclosures |

Do not declare Health Connect sleep data as collected while it remains entirely on-device. Do not declare analytics, advertising, crash reporting, or developer-operated telemetry; the app does not contain those services.

Security answers:

- All collected data encrypted in transit: **No**. Enve permits user-configured LAN servers over HTTP.
- Data deletion request mechanism: **No developer-operated mechanism**. Enve does not operate user accounts or servers; users remove local data in the app and manage remote data with the service they configured.
- Independent security review: **No**, unless a qualifying review is completed before submission.

Before submission, compare this draft with the current Google Play SDK Index entries for every Google SDK in the signed bundle and update any affected data type.

## Other App content answers

- Ads: **No**
- App access: core local playback does not require an account. Optional providers require credentials supplied by the user.
- News app: **No**
- Government app: **No**
- Financial features: **No**, apart from the optional Play Billing tip product.
- Target audience, countries, pricing, store category, and content-rating answers remain owner decisions.

## Store assets

Prepare current, private-data-free images for:

- phone
- tablet
- Android Auto
- Wear OS

Do not use screenshots that show private server addresses, account names, tokens, personal health records, or identifiable library history.

## Official references

- [Google Play Data safety](https://support.google.com/googleplay/android-developer/answer/10787469)
- [Health apps declaration](https://support.google.com/googleplay/android-developer/answer/14738291)
- [Publishing a Health Connect app](https://developer.android.com/health-and-fitness/health-connect/publish)
- [Health Connect permissions policy](https://support.google.com/googleplay/android-developer/answer/16558241)
- [Health content and services policy](https://support.google.com/googleplay/android-developer/answer/16679511)
