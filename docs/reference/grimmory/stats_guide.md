# Grimmory Stats API: Integration Guide

This document details the various data visualization and statistics endpoints available in the Grimmory server. All of these endpoints are sourced from the UserStatsController (`/api/v1/user-stats`).

> [!IMPORTANT]
> All endpoints below require a valid JWT token passed via the `Authorization: Bearer <TOKEN>` header.

---

## 📖 1. General Reading Statistics

### Reading Streak
Retrieves the user's current reading streak, longest streak, and a 52-week activity map.
* **Endpoint:** `GET /api/v1/user-stats/reading/streak`
* **Response:**
```json
{
  "currentStreak": 7,
  "longestStreak": 14,
  "totalReadingDays": 45,
  "last52Weeks": [
    { "date": "2025-03-20", "active": false },
    { "date": "2026-03-26", "active": true }
  ]
}
```

### Book Distributions
Returns the breakdown of the user's library by star rating, progress percentage, and read status.
* **Endpoint:** `GET /api/v1/user-stats/reading/book-distributions`
* **Response:**
```json
{
  "ratingDistribution": [ /* Array of rating vs count */ ],
  "progressDistribution": [
    { "range": "Completed", "min": 100, "max": 100, "count": 12 },
    { "range": "Not Started", "min": 0, "max": 0, "count": 5 }
  ],
  "statusDistribution": [
    { "status": "READING", "count": 13 },
    { "status": "ABANDONED", "count": 3 }
  ]
}
```

### Reading Heatmap (Yearly)
Returns daily session counts over an entire calendar year.
* **Endpoint:** `GET /api/v1/user-stats/reading/heatmap?year=2026`
* **Response:** Array of `{ "date": "2026-03-25", "count": 14 }`

### Reading Timeline (Weekly)
Returns active reading sessions grouped by book for a specific calendar week.
* **Endpoint:** `GET /api/v1/user-stats/reading/timeline?year=2026&week=13`
* **Response:**
```json
[
  {
    "bookId": 72,
    "bookTitle": "Zadig or L'Ingenu",
    "bookType": "EPUB",
    "startDate": "2026-03-23T11:21:18",
    "endDate": "2026-03-23T11:33:11",
    "totalSessions": 1,
    "totalDurationSeconds": 713
  }
]
```

### Session Scatter Plot
Returns individual reading session data points for plotting on a 24-hour hour-of-day vs day-of-week graph.
* **Endpoint:** `GET /api/v1/user-stats/reading/session-scatter?year=2026`
* **Response:**
```json
[
  {
    "hourOfDay": 13.0, 
    "durationMinutes": 15.0, 
    "dayOfWeek": 5 
  }
]
```

### Page Turner Scores (Grip Score)
Calculates a "grip score" (0-100) based on how quickly a user finished a book and if their session durations accelerated. 
* **Endpoint:** `GET /api/v1/user-stats/reading/page-turner-scores`
* **Response:** Array of scores with `gripScore`, `sessionAcceleration`, and `finishBurst`.

### Completion Race
Provides progress snapshots for books completed in a specific year to visualize how long different books took to finish.
* **Endpoint:** `GET /api/v1/user-stats/reading/completion-race?year=2026`

---

## 🎧 2. Audiobook & Listening Statistics

### Listening Completion Progress
Returns overall audiobook completion stats and a list of currently in-progress audiobooks.
* **Endpoint:** `GET /api/v1/user-stats/listening/completion`
* **Response:**
```json
{
  "totalAudiobooks": 2,
  "completed": 2,
  "inProgressCount": 0,
  "inProgress": [
    {
       "bookId": 94,
       "title": "Spellmonger",
       "progressPercent": 45.5,
       "totalDurationSeconds": 36000,
       "listenedDurationSeconds": 16380
    }
  ]
}
```

### Listening Heatmap (Monthly)
Returns daily totals for audiobook listening sessions and minutes.
* **Endpoint:** `GET /api/v1/user-stats/listening/heatmap/monthly?year=2026&month=3`
* **Response:**
```json
[
  {
    "date": "2026-03-24",
    "sessions": 3,
    "durationMinutes": 1
  }
]
```

### Weekly Listening Trend
Returns the total hours listened per week over the last `N` weeks (defaults to 26).
* **Endpoint:** `GET /api/v1/user-stats/listening/weekly-trend?weeks=26`
* **Response:**
```json
[
  {
    "year": 2026,
    "week": 13,
    "totalDurationSeconds": 39,
    "sessions": 3
  }
]
```

### Audiobook Finish Funnel
Shows retention rates for audiobooks across specific progress milestones (Started, Reached 25%, 50%, 75%, Completed).
* **Endpoint:** `GET /api/v1/user-stats/listening/finish-funnel`
* **Response:**
```json
{
  "totalStarted": 2,
  "reached25": 2,
  "reached50": 2,
  "reached75": 2,
  "completed": 2
}
```
