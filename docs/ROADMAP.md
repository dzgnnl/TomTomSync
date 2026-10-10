# Roadmap

## Open

- **Apple Developer ID signing and notarization.** Only if there is enough interest,
  since it costs USD 99/year. It would give warning-free downloads, a listing in the
  official `homebrew/cask`, Keychain storage for the Strava login, and in-app
  auto-updates via [Sparkle](https://sparkle-project.org). `build-app.sh` already
  supports signing ([details](DEVELOPMENT.md#releases)).
- **Device names on Strava.** Currently shown as "TomTom GPS Watch". Needs a
  confirmed mapping from product ID to model.
- **Test more watches**, especially the first generation (`0x7474`) and Spark Cardio (`0x7477`).
- **Default for "delete after export"**: consider off for new users.
- **Relaunch after `brew upgrade`**: upgrading quits the app.

## Maybe later

Features TomTomWatch has: GPX export, routes, workouts and races, activity
tracking, watch preferences.
