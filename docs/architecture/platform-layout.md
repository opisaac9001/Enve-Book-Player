# Platform Layout

Enve Book Player is implemented as two native applications in one public repository.

The `ios/` project owns Apple-platform UI, playback, reading, persistence, providers, Watch, widgets, and tvOS. The `android/` project owns Android and Wear OS equivalents using its own Gradle modules and platform libraries.

The projects deliberately share product vocabulary and backend behavior, but they do not share application source or force platform-specific concepts into a common abstraction. Each platform's local architecture guide is authoritative for its tree.
