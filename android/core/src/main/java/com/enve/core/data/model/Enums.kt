package com.enve.core.data.model

import kotlinx.serialization.Serializable

@Serializable
enum class AppMediaType {
    AUDIOBOOK,
    EBOOK,
    PODCAST
}

@Serializable
enum class BookSource(val displayName: String) {
    GRIMMORY("Grimmory"),
    STORYTELLER("Storyteller"),
    AUDIOBOOKSHELF("Audiobookshelf"),
    JELLYFIN("Jellyfin"),
    PLEX("Plex"),
    EMBY("Emby"),
    KOMGA("Komga"),
    KAVITA("Kavita"),
    BOOKORBIT("BookOrbit"),
    SILO("Silo"),
    OPDS("OPDS"),
    WEBDAV("WebDAV"),
    TORBOX("TorBox"),
    PREMIUMIZE("Premiumize"),
    REALDEBRID("Real-Debrid"),
    SMB("SMB Share"),
    LOCAL("Local Files");

    companion object {
        val serverProviders = listOf(
            GRIMMORY,
            STORYTELLER,
            AUDIOBOOKSHELF,
            JELLYFIN,
            PLEX,
            EMBY,
            KOMGA,
            KAVITA,
            BOOKORBIT,
            SILO,
            OPDS,
            WEBDAV,
            TORBOX,
            PREMIUMIZE,
            REALDEBRID,
            SMB,
        )
    }
}

enum class ReadStatus {
    UNREAD,
    IN_PROGRESS,
    ON_HOLD,
    COMPLETED
}

enum class LibraryLayout(val columns: Int, val displayName: String, val iconName: String) {
    LIST(1, "List", "list.bullet"),
    TWO_COLUMN(2, "2 Columns", "square.grid.2x2"),
    THREE_COLUMN(3, "3 Columns", "square.grid.3x3"),
    FOUR_COLUMN(4, "4 Columns", "square.grid.4x3.fill"),
    FIVE_COLUMN(5, "5 Columns", "square.grid.3x3.fill");
}

enum class BookCardStyle(val displayName: String, val description: String) {
    STANDARD("Standard", "Cover with title, author, and narrator"),
    COMPACT("Compact", "Cover with a smaller title only"),
    COVER_ONLY("Cover Only", "Just the cover as a tile");
}

enum class SortOption(val displayName: String) {
    TITLE("Title"),
    AUTHOR("Author"),
    AUTHOR_SURNAME("Author (Surname)"),
    DATE_ADDED("Date Added"),
    NARRATOR("Narrator"),
    PROGRESS("Progress"),
    DURATION("Duration"),
    PUBLISHED_YEAR("Published Year"),
    SERIES_ORDER("Series Order");
}

enum class SortDirection {
    ASCENDING,
    DESCENDING
}

@Serializable
enum class ConnectionAuthMode(val displayName: String) {
    AUTO("Auto"),
    USERNAME_PASSWORD("Username & Password"),
    TOKEN("Token / API Key"),
    SSO("Single Sign-On"),
}

@Serializable
enum class UrlScheme(val prefix: String, val displayName: String) {
    HTTP("http://", "HTTP"),
    HTTPS("https://", "HTTPS"),
}

enum class BrowseTab(val displayName: String, val icon: String) {
    DISCOVER("Discover", "explore"),
    SERIES("Series", "book"),
    AUTHORS("Authors", "person"),
    NARRATORS("Narrators", "mic"),
    COLLECTIONS("Collections", "folder");
}

enum class TitleDisplayMode(val displayName: String, val description: String, val example: String) {
    PRESERVE("Preserve", "Show titles exactly as stored", "\"01 - The Hobbit\" stays as-is"),
    STRIP_PREFIX("Strip Prefix", "Remove leading numbers and separators", "\"01 - The Hobbit\" → \"The Hobbit\""),
    MOVE_TO_SUFFIX("Move to Suffix", "Rewrite prefix as parenthetical suffix", "\"01 - The Hobbit\" → \"The Hobbit (Book 1)\""),
    EXTRACT_TO_SERIES("Extract to Series", "Pull prefix out as series metadata", "\"01 - The Hobbit\" → Series: #1");
}

enum class SubtitleHandling(val displayName: String, val example: String) {
    KEEP("Keep Subtitles", "\"The Hobbit: An Unexpected Journey\""),
    REMOVE("Remove Subtitles", "\"The Hobbit: An Unexpected...\" → \"The Hobbit\"");
}

enum class MergeAggressiveness(val displayName: String, val description: String, val threshold: Int) {
    CONSERVATIVE("Conservative", "Only merge near-exact matches", 95),
    NORMAL("Normal", "Balanced deduplication", 85),
    AGGRESSIVE("Aggressive", "Group loosely similar titles", 70);
}
