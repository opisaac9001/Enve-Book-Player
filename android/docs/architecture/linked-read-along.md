# Linked read along

Linked read along follows an ordinary EPUB while its linked audiobook plays in the main player. It is separate from classic EPUB 3 media-overlay read aloud: books with SMIL keep using `MediaOverlayEngine`, and nothing here writes, rewrites or reinterprets SMIL. StoryAlign's full-book conversion is also unchanged; it never requests word timings.

The design follows the iOS `ReaderLinkedReadAlongController` and `PassageAlignmentService`. Android keeps the same vocabulary but runs one preparation session per open reader instead of a profile-wide queue.

## Components

| Type | Module | Responsibility |
| --- | --- | --- |
| `PassageAlignmentService` | `:engine` | Owns the follow session: text index, media identity, saved windows, the QuartzNet worker, the read-along loop and the reading-to-listening handoff. |
| `PassageTimeline` | `:engine` | Pure window bookkeeping: analyzed, rejected, failed and in-progress windows, selected sentences, audio and text resolution, handoff search and retry. |
| `PassageTextResolver` | `:engine` | Resolves reader text to an original sentence and chooses the seek position. |
| `PassageWordTiming` | `:engine` | Validated word timings and their quote context. |
| `PassageClock` | `:engine` | Live playback clock between the player's 250 ms position updates. |
| `CtcBookMatcher` | `:engine` | Sentence matching and, when constructed with `wordTimings = true`, word timings from the forced alignment. |
| `HearthLinkedReadAlongPanel` | `:app` | Status, transport, follow, listen-from-page and retry controls. |

## Preparation states

The service reports one `PassagePreparationState` per tick. The state at the playhead comes from the 30 second window containing it and the following window, because a sentence belongs to the window in which it ends.

| Condition | Message | Retry |
| --- | --- | --- |
| Sentence at the playhead | Following audiobook, with mapping and optional word | No |
| Pause of 2 seconds or less between adjacent sentences | Following audiobook, previous sentence kept | No |
| Analyzed audio without book text | Following audiobook, no highlight | No |
| Window being analyzed | Matching the narrated passage | No |
| Window not analyzed yet | Waiting for this passage, or the worker's pause reason | No |
| Decoding or inference failed | Couldn't analyze this part of the audiobook | Yes |
| Analyzed without a confident sentence | No confident match for this part of the audiobook | Yes |

Failed and rejected windows are never analyzed again automatically. **Try again** clears them from 30 seconds before the playhead to 120 seconds after it, so the worker analyzes them on its next pass. A model, cache or storage failure still ends the session with an error.

## Reading to listening

**Listen from here** in the selection menu uses the Readium selection locator. **Listen from this page** in the panel uses the first visible text element. Both call `PassageAlignmentService.findListeningPosition`.

1. The quote is compared with original sentences in the same document. Comparison ignores case and punctuation.
2. If several sentences match, the 24 normalized characters before and after the selection decide. Reading progression decides only when the nearest candidate is more than 0.05 closer than the next one. Otherwise the result is ambiguous and playback is not moved.
3. A selection that begins in one sentence and continues into the next resolves to the first sentence.
4. A prepared sentence seeks to its start. When its words are timed and the selection's first words occur once in it, playback seeks 0.16 seconds before the first timed word at or before the selection.
5. An unprepared sentence starts a handoff. Its position is interpolated between the nearest prepared sentences, or estimated from its share of the book text. Up to 16 windows within 10 minutes of the estimate are analyzed, nearest first, before ordinary look-ahead. The estimate is recomputed after each window. Handoff analysis continues in battery saver; thermal, background and storage pauses still apply.
6. A sentence between adjacent narrated sentences that are less than 3 seconds apart is reported as not narrated.
7. The search ends after 30 seconds. A newer request replaces an older one.

Only a matched sentence moves playback. Ambiguous, unnarrated, missing and unprepared text leaves the listening position unchanged. If the request started read along, read along stops again. While the search runs, following does not turn pages or change highlights.

## Word timings

QuartzNet is a character CTC model, and Android's forced alignment already returns a frame range for every character. When word timings are requested, each printed word is mapped to its characters:

- Printed words come from Unicode word boundaries. A hyphen or apostrophe between two words joins them into one target.
- Each word and each gap between words is normalized with the same `WordNormalizer` path as the sentence. If the concatenation differs from the sentence's normalized text, as it can with number or symbol expansion, the sentence gets no word timings.
- A word is timed from its first character's start frame to its last character's end frame, less the 0.12 second emission lag used for sentence ends, and clamped to the sentence.
- A word qualifies only if every character has log probability of at least −4, the mean is at least −2, its duration is between 0.04 seconds and the larger of 1.5 seconds and 0.25 seconds per character, and an adjacent word also qualifies.
- At display, every word must be a printed word of the sentence, words must be in order without overlap, and words are clipped to the selected sentence end. Any other violation drops all word timings for that sentence.

No timing is interpolated or estimated. Words that do not qualify are not highlighted, and the sentence highlight remains. A word stays highlighted across a gap of 0.25 seconds or less before the next word, so peaky CTC output does not flicker. The read-along loop ticks every 50 ms while timed words are playing, and every 200 ms otherwise.

The word decoration uses its own Readium decoration group. It locates the word by its text with up to 64 characters of context from the same sentence. Neighbouring sentence text is used only at a sentence edge.

## Saved windows

Windows are saved under `passage-alignment/` in the profile's files directory, keyed by both books. The identity covers both book keys, EPUB digest, model, track layout, audio revisions and the saved-format tag `passage-words-v1`. Windows saved before word timings do not match and are prepared again. Windows for tracks that are no longer in the layout are ignored.

## Manual verification

1. Link an English EPUB without media overlays to its audiobook. Start read along from the reader controls and confirm the indexing, identifying, model and matching messages before following begins.
2. Confirm that the sentence highlight follows narration and turns pages, and that a stronger word highlight moves with speech in clearly narrated passages.
3. Seek into credits or other untimed audio. Confirm that the highlight clears without an error.
4. Turn off networking while streaming the audiobook so a window fails. Confirm **Try again** appears, then restore networking and confirm **Try again** recovers.
5. Select a mid-sentence phrase on another page and choose **Listen from here**. Playback should start at that phrase and following should resume.
6. Select one word that repeats on the page. Playback must not move, and the ambiguity message should appear.
7. Select a chapter heading that is not narrated. Playback must not move.
8. Browse away while following, then choose **Listen from this page**.
9. Close the reader during a handoff search. Confirm that playback does not move afterwards.
10. Open a book with SMIL media overlays. Confirm classic read aloud is unchanged and the linked read-along actions do not appear.
