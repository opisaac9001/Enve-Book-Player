# AZW3 reader verification

AZW3 files use Foliate directly after Grimmory download or local-file resolution. They do not enter MOBI-to-EPUB conversion, HTML extraction, or Readium fallback. Existing positions from converted EPUBs resume by percentage; subsequent opens restore the Foliate locator.

The pinned Foliate runtime includes its MOBI/KF8 parser and fflate for compressed Kindle fonts. The embed script declares both fflate and its license as Xcode inputs and outputs; the WebView runtime allowlist includes the parser, decompressor, and AZW3 resource path.

Build and run the `enve` scheme on iPhone Air using the workspace's designated DerivedData directory. Run the `AllTests` plan with `ENVE_AZW3_FIXTURE_BASE64` in the test-runner environment to enable `Azw3ReaderTests`. XcodeBuildMCP accepts this through `testRunnerEnv`; command-line Xcode uses the `TEST_RUNNER_` prefix. Without a supplied fixture, that test is skipped.

The regression test opens a genuine KF8 file through `ClassicReaderModel` for Grimmory and local books, checks the Foliate engine even with a Readium override, navigates, reopens at the saved location, and verifies no EPUB was created. Its profile storage is isolated from the user's library.

The workspace's existing libmobi `sample-obfuscated-fonts.mobi` fixture has a version-8 header and can be used with an `.azw3` filename. For visual verification, stage it in the simulator app's Documents folder and launch the existing debug route with `-imagineScreen footnotefixture -imagineFixture <filename>.azw3`. Confirm text renders and swiping turns pages.
