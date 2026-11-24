# Google Cast 4.8.6

This package uses Google's unmodified dynamic SDK archive and its published SHA-256 checksum from [the official package](https://github.com/googlecast/google-cast-ios-sdk/tree/4.8.6).

The dynamic binary already contains GTMSessionFetcher. The upstream manifest also links a separate copy, producing duplicate Objective-C class registrations at launch. This wrapper links the binary once, with its bundled UI resources, and omits that redundant dependency. Recheck this workaround when updating the SDK.

The binary is governed by the [Google Cast SDK Additional Developer Terms of Service](https://developers.google.com/cast/docs/terms). Its bundled third-party notices remain in the framework.
