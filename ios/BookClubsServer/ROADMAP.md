# Enve Book Club roadmap

Book Club gives a reading group a home on a server someone in the group can run. Members can join several clubs, read or listen on their own devices, and choose how much reading activity to share. Enve for iOS puts each club’s current read on Hearth. The browser client works from the instance’s address, and both clients use the same [documented API](protocol/BOOK-CLUB.md).

## What to borrow

| Product | What it does well | How it fits Book Club |
| --- | --- | --- |
| Tome | Library sharing, offline audiobooks, and discussion by chapter | Keep shared copies easy to download and bring readers back to the matching discussion. [Tome](https://github.com/tome-project/tome) |
| HomeBranch | Edition-aware plans, pinned organizer prompts, spoiler-marked posts, and public or private clubs | Prompts and per-post spoilers are available now. Edition mapping and same-instance club discovery are next candidates. [HomeBranch book clubs](https://homebranch.app/book-clubs/) |
| Witbound | Dated stages, group progress on a visual track, and reading presence | Build on the visual track and optional presence with better edition mapping and scheduling. [Witbound](https://witbound.co.uk/) |
| Luma | Self-hosted library access, browser reading, and discussion | Take a hosted copy straight into reading or listening in the browser. [Luma](https://github.com/netpersona/Luma) |
| Fable | Chapter rooms and shared highlights alongside the text | Bring comments and reactions into the reader around the passages they refer to. [Fable club features](https://fable.co/club-features), [Fable Social Mode](https://help.fable.co/article/39-what-is-social-mode) |
| BookFusion | Selective sharing of reading annotations | Give readers a visibility choice on each annotation when shared highlights move into the reader. [BookFusion social features](https://support.bookfusion.com/hc/en-us/sections/4411261170317-Social-Features-Beta) |
| The StoryGraph | Buddy reads for small groups and checkpoint discussions for larger readalongs | Support the same reading plan and spoiler controls from a small circle through a larger club. [The StoryGraph](https://thestorygraph.freshdesk.com/support/solutions/articles/79000141943-buddy-reads-and-readalongs-on-the-storygraph) |
| Bookmark | Edition linking and voting on the next read | Improve progress across editions and surface results beside the current book. [Bookmark](https://apps.apple.com/us/app/bookmark/id6757299789) |
| Bookclubs | Meeting polls, RSVPs, and reminders | Add club events and calendar export to the existing plan and reading reminders. [Bookclubs](https://bookclubs.com/) |
| BookWyrm | Profiles, follows, and federation | Add opt-in social features within an instance first. Explore federation after visibility and moderation behavior is well defined. [BookWyrm](https://github.com/bookwyrm-social/bookwyrm) |

## Current shared foundation

- Separate clubs, club display names, invitations, reading plans, manual check-ins, optional progress and presence, discussion, reactions, nominations, and votes.
- Per-thread host prompts, individual spoiler reveals, private or shared reading notes, and an activity feed across the member’s clubs.
- Catalog adapters for OPDS, Grimmory, and Audiobookshelf. The homelab runtime can import an authorized copy for the club, and members can download it or bring their own edition.
- Enve’s Hearth shows current reads for active memberships on its configured instance. A card previews the member’s next checkpoint and opens the reading plan, discussion, and notes. The browser lists all joined clubs and provides the same activity feed. Post activity opens its discussion and highlights the post in both clients.

## Implementation order

1. **Connect multiple instances in Enve.** Let members add an instance by address or invitation and use multiple instances at once. Carry the origin in routes and local keys for sessions, club IDs, invitations, linked copies, and pending progress. Group cards and activity across the member’s connections, with an instance name when needed for context.
2. **Add profiles and discovery on one instance.** Make a member’s profile, follows, and public club listing explicit choices. Keep private club membership, posts, check-ins, and notes visible to their existing audiences.
3. **Tie discussion to reading.** Let a host map checkpoints between editions, including ebooks and audiobooks. Add passage links and shared annotations inside the reader, with checkpoint gating and a private default for personal notes.
4. **Make it easier to run a club.** Build meeting polls, RSVPs, and calendar export around the club’s existing book votes, checkpoints, and reminders. Add a browser reader and player for formats the instance already serves.
5. **Extend interoperability.** Add portable exports and versioned capability contracts for independent clients. Treat cross-instance federation as a separate feature with its own audience, moderation, and deletion rules.
