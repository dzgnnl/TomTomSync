# TomTomSync

A macOS menu bar app that keeps your TomTom sports watch working now that
MySports is gone. When you plug in the watch, it:

- saves new activities as `.fit` files (for Strava, Garmin Connect, Runalyze, …)
- uploads them to Strava (optional)
- updates GPS QuickFix, so the watch finds GPS in seconds
- sets the watch's time zone
- clears the watch after a verified export (optional)

Works with the Spark, Spark 3, Runner 2/3 and Adventurer; tested on a Spark 3 Music.
First-generation Multi-Sport/Runner watches should work but are untested.
Requires macOS 14 or newer.

> Hobby project, not affiliated with TomTom, Strava or Garmin. Use at your own risk.

## Install

1. Install [Homebrew](https://brew.sh) if you don't have it.
2. In Terminal, run:
   ```sh
   brew install --cask dzgnnl/tap/tomtomsync
   ```
3. Open **TomTomSync** from Applications. A 🏃 icon appears in the menu bar.
4. Plug in the watch. If macOS asks to allow the accessory, click **Allow**.

**Update:** `brew upgrade`, then start TomTomSync again.
**Start at login:** 🏃 → **Settings…** → **Launch at login**.

## Use

- 🏃 shows the sync status, a **Sync** button and your recent activities with
  their Strava upload status. Click the status line for the log.
- Files are saved in `~/TomTom/fit` (`.fit`) and `~/TomTom/ttbin` (the watch's original files).
- **Settings…** turns each step on or off. All are on by default.

## Connect Strava

Strava requires every user to create their own free API application:

1. At <https://www.strava.com/settings/api>, create an application. Use any name
   and website, category **Data Importer**, and **Authorization Callback Domain** `localhost`.
2. In TomTomSync, open **Settings…** → **Strava**, paste the **Client ID** and **Client
   Secret**, and click **Connect to Strava…**.
3. In the browser, keep **Upload your activities** ticked and click **Authorize**.

New activities are uploaded from then on. Activities shorter than a minute are
skipped, and duplicates are detected.

## Troubleshooting

- **Watch not detected:** reseat the watch firmly in the cradle (it should show it's
  charging) and try another USB port. Check **System Settings → Privacy & Security →
  Allow accessories to connect**.
- **"Apple could not verify…"** (only for a ZIP downloaded from Releases):
  **System Settings → Privacy & Security → Open Anyway**.
- **Strava errors:** **Settings… → Disconnect Strava**, then connect again.

## Uninstall

`brew uninstall --cask --zap tomtomsync` removes the app, settings and Strava login.
Your activities in `~/TomTom` are kept.

## More

- [Technical documentation](docs/DEVELOPMENT.md): building from source, command line, releases, protocol
- [Roadmap](docs/ROADMAP.md) · [Credits](CREDITS.md) · [Security](SECURITY.md) · [MIT License](LICENSE)

Built on the reverse engineering of Jorgen van der Velde
([TomTomWatch](https://github.com/scubajorgen/TomTomWatch)) and Ryan Binns
([ttwatch](https://github.com/ryanbinns/ttwatch)).
TomTom, Strava, Garmin and FIT are trademarks of their owners.
