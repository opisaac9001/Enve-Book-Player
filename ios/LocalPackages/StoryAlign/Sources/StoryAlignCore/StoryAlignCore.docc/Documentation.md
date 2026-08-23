

# ``StoryAlignCore``

StoryAlignCore is the library behind storyalign. It combines an ebook with an audiobook to produce
a narrated epub containing media overlays and synchronized highlighting.



### Quickstart

```
// Setup the alignment session
let req = try AlignmentRequest(
    epubURL: epubURL,
    audioBookURLs: [audioBookURL],
)
let cfg = AlignmentConfig(
    granularity: granularity
)
let session = AlignmentSession(
    request: req,
    config: cfg,
    speechAnalyzerConfig: SpeechAnalyzerConfig()
)
defer { session.cleanup() }

// Run the alignment
let result = try await StoryAligner().alignStory(session: session)

// Move/copy the narrated epub to wherever you want it.
try FileManager.default.moveItem(at: result.alignedEpubURL, to: outputURL)

```

## Topics

### Running an alignment

- ``StoryAligner``
- ``AlignmentSession``
- ``AlignmentRequest``
- ``AlignmentConfig``
- ``AlignmentResult``

### Progress

- ``ProgressListener``
- ``ProgressSnapshot``
- ``ProgressStage``

