# Tasker and automation controls

Enve supports Android media controllers and explicit broadcast intents. Tasker's **Media Control** action can target Enve for play, pause, stop, and audiobook skip controls. Enable **Use Notification If Available** when Enve has an active media notification.

For deterministic tasks, use Tasker's **Send Intent** action with:

- **Package:** `com.enve.app`
- **Target:** `Broadcast Receiver`
- **Action:** one of the actions below

| Action | Behavior | Extra |
|---|---|---|
| `com.enve.app.action.PLAY` | Start or resume playback | — |
| `com.enve.app.action.PAUSE` | Pause playback | — |
| `com.enve.app.action.TOGGLE_PLAYBACK` | Toggle play and pause | — |
| `com.enve.app.action.STOP` | Stop playback | — |
| `com.enve.app.action.SKIP_FORWARD` | Skip by Enve's configured forward interval | — |
| `com.enve.app.action.SKIP_BACKWARD` | Skip by Enve's configured backward interval | — |
| `com.enve.app.action.NEXT_CHAPTER` | Seek to the next chapter | — |
| `com.enve.app.action.PREVIOUS_CHAPTER` | Seek to the previous chapter | — |
| `com.enve.app.action.SEEK_TO` | Seek to an absolute audiobook position | `position_ms` as a non-negative integer |
| `com.enve.app.action.SEEK_BY` | Seek relative to the current audiobook position | `offset_ms` as a signed integer |
| `com.enve.app.action.SET_SPEED` | Set playback speed from 0.5× through 3.0× | `speed` as a decimal |

The seek extras use milliseconds. For example, `offset_ms:30000` moves forward 30 seconds and `offset_ms:-30000` moves backward 30 seconds. Enve accepts Tasker integer, long, float, and double numeric extras.

The same actions can be tested through ADB:

```sh
adb shell am broadcast -a com.enve.app.action.PLAY -p com.enve.app
adb shell am broadcast -a com.enve.app.action.SEEK_BY --el offset_ms 30000 -p com.enve.app
adb shell am broadcast -a com.enve.app.action.SET_SPEED --ef speed 1.5 -p com.enve.app
```

For a debug build, replace the package with `com.enve.app.debug`. The action names remain unchanged.

The exported automation receiver accepts playback transport commands only. It does not expose libraries, credentials, downloads, or queue mutation.
