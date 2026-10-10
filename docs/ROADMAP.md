# Roadmap

## Open

- **Music and podcast sync** ([#1](https://github.com/dzgnnl/TomTomSync/issues/1)).
  Music watches mount as a FAT32 drive with m3u8 playlists, so this needs no USB
  protocol work. Sources: Music.app playlists, a folder, podcast feeds.
- **Route upload** ([#2](https://github.com/dzgnnl/TomTomSync/issues/2)). GPX files,
  and later starred Strava routes, to the watch.
- **Export to more sites** ([#3](https://github.com/dzgnnl/TomTomSync/issues/3)).
  intervals.icu first (open API), then Runalyze, plus an export folder. Garmin
  Connect, Runkeeper and Nike Run Club have no open upload API.
- **Apple Developer ID signing and notarization.** Only if there is enough interest,
  since it costs USD 99/year. It would give warning-free downloads, a listing in the
  official `homebrew/cask`, Keychain storage for the Strava login, and in-app
  auto-updates via [Sparkle](https://sparkle-project.org). `build-app.sh` already
  supports signing ([details](DEVELOPMENT.md#releases)).
- **Test more watches**, especially the first generation (`0x7474`) and Spark Cardio (`0x7477`).
- **Relaunch after `brew upgrade`**: upgrading quits the app.

## Maybe later

Features TomTomWatch has: GPX export, workouts and races, activity
tracking, watch preferences.
