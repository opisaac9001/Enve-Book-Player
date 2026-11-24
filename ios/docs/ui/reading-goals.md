# Daily reading goals

Journal and its Reading screen share an optional daily minutes goal. The setting belongs to the captured `ProfileSession.readingGoal` and is stored in that profile's defaults. A new profile has no enabled goal. The editor starts at 20 minutes and accepts 1–240 minutes; Save applies the draft, Cancel leaves it unchanged, and Turn off removes the goal without changing reading history.

Progress uses `ReadingStatsSnapshot.dailySecondsRead`, including the reading history already merged by the existing tracker. Listening time is not added. There is no second timer, progress upload, notification permission, or new statistics writer. Changing the target immediately re-evaluates today's recorded reading time. The bar stops at 100%; completion requires all target seconds, rather than rounding up elapsed minutes.

Today uses the current time zone and the ledger's Gregorian `yyyy-MM-dd` keys, even if the device's display calendar is non-Gregorian. The view reevaluates the day on its minute schedule and when returning to the foreground. Existing history retains its recorded day labels; enabling a goal does not reassign historical sessions or rewrite streaks.

Apple references checked for this implementation: [Calendar](https://developer.apple.com/documentation/foundation/calendar), [TimelineView](https://developer.apple.com/documentation/swiftui/timelineview), [ProgressView](https://developer.apple.com/documentation/swiftui/progressview), and [Stepper](https://developer.apple.com/documentation/swiftui/stepper).
