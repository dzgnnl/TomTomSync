# TomTomSync

A macOS menu bar app that keeps your TomTom sports watch working now that
MySports is gone. When you plug in the watch, it:

- saves new activities as `.fit` files (for Strava, Garmin Connect, Runalyze, …)
- uploads them to Strava (optional)
- updates GPS QuickFix, so the watch finds GPS in seconds
- sets the watch's time zone
- copies GPX files and starred Strava routes to the watch (Runner 3, Spark 3, Adventurer)
- clears the watch after a verified export (optional)

Works with the Spark, Spark 3, Runner 2/3 and Adventurer. Tested on a Spark Music
(activities, QuickFix, time zone) and a Runner 3 (routes).
First-generation Multi-Sport/Runner watches should work but are untested.
Requires macOS 14 or newer.

> Unofficial hobby project, not affiliated with or endorsed by TomTom, Strava or Garmin.
> Use at your own risk: TomTomSync writes to your watch with a reverse-engineered
> protocol, and TomTom's own software can no longer restore a watch.

## Install

1. Install [Homebrew](https://brew.sh) if you don't have it.
2. In Terminal, run:
   ```sh
   brew install --cask dzgnnl/tap/tomtomsync
   ```
3. Open **TomTomSync** from Applications. A 🏃 icon appears in the menu bar.
4. Plug in the watch. If macOS asks to allow the accessory, click **Allow**.

**Update:** TomTomSync tells you when a new version is available. Run `brew upgrade tomtomsync`, then start TomTomSync again.

**Start at login:** 🏃 → **Settings…** → **Launch at login**.

## Use

- 🏃 shows the sync status, a **Sync** button and your recent activities with
  their Strava upload status. Click the status line for the log.
- Files are saved in `~/TomTom/fit` (`.fit`) and `~/TomTom/ttbin` (the watch's original files).
- **Settings…** turns each step on or off. All are on by default, including clearing
  the watch after a verified export; only [routes](#routes) are off until you turn them on.
- A second-hand watch may still hold the previous owner's activities. They are saved
  and uploaded like your own, so turn off Strava upload for its first sync.

## Routes

Runner 3, Spark 3 and Adventurer can show a route during a run, ride or other GPS activity.
Route sync is off by default: turn on **Sync routes to the watch** in 🏃 → **Settings… → Routes**.
On the watch, open the activity's **Settings → Trails**.

- Put GPX files in `~/TomTom/routes` (🏃 → **Settings…** → **Open Routes Folder**).
  Every sync makes the watch match the folder: up to 15 routes, your own files
  first, newest first. Removing a file removes the route from the watch.
- With Strava connected, your starred Strava routes are added in `routes/Strava`
  (managed by the app; unstar a route to remove it). Runs by default; walks and rides
  can be turned on in **Settings… → Routes**. If you connected Strava before v0.2.0,
  disconnect and connect again to include private routes.
- The first sync of a watch saves the routes already on it to the folder, so nothing is lost.
- Long routes are simplified to 500 points (the limit MySports used); corners stay
  where they are.

## Connect Strava

For now, you create your own free Strava API application. A shared TomTomSync
app would need a server to keep its secret safe; that may come later ([#6](https://github.com/dzgnnl/TomTomSync/issues/6)).

1. At <https://www.strava.com/settings/api>, create an application. Use any name
   and website, category **Data Importer**, and **Authorization Callback Domain** `localhost`.
2. In TomTomSync, open **Settings…** → **Strava**, paste the **Client ID** and **Client
   Secret**, and click **Connect to Strava…**.
3. In the browser, keep **Upload your activities** ticked and click **Authorize**.

New activities are uploaded from then on, and duplicates are detected. An upload
that fails is tried again at the next sync. Activities under a minute, or outdoor ones
under 10 m, are not uploaded automatically; use the **Upload** button next to them.

## Troubleshooting

- **Watch not detected:** reseat the watch firmly in the cradle (it should show it's
  charging) and try another USB port. Check **System Settings → Privacy & Security →
  Allow accessories to connect**.
- **"Apple could not verify…"** (only for a ZIP downloaded from Releases):
  **System Settings → Privacy & Security → Open Anyway**.
- **Routes don't appear:** only Runner 3, Spark 3 and Adventurer have Trails, and route
  sync has to be turned on in **Settings… → Routes**. Click the
  status line for the log: a GPX file that can't be read stops the route sync until it
  is fixed or removed.
- **Strava errors:** **Settings… → Disconnect Strava**, then connect again.

## Privacy

Your activities, routes and Strava login stay on your Mac; activities go to Strava
only if you connect it. The app also downloads GPS QuickFix data from TomTom and asks
GitHub once a day whether there is a new version (**Settings… → Check for updates**).
Those servers see your IP address, as with any web request.

To see whether the app is still used, and so worth maintaining, TomTomSync sends one anonymous signal a day to
[TelemetryDeck](https://telemetrydeck.com) (EU-based, stores no IP addresses). The
signal contains:
- the app version and macOS version,
- the watch model (a product code such as `0x07DE`),
- whether Strava is connected,
- a random installation ID, hashed, so installations can be counted but not identified,
- the time of sending and a random ID per signal.

It contains nothing about your activities, locations, name, accounts or watch serial
number. Nothing is sent before the first-launch notice, which has a **Turn Off**
button; later, use **Settings… → Send anonymous usage statistics**. `ttsync` sends
nothing, and neither does a copy you build yourself or a fork's release. The statistics are only used to count installations; questions can go to
[Tako Bruinsma](https://github.com/dzgnnl) via an issue. The code is in
[`Telemetry.swift`](Sources/TomTomKit/Sync/Telemetry.swift).

## Uninstall

`brew uninstall --cask --zap tomtomsync` removes the app, settings and Strava login.
Your activities in `~/TomTom` are kept.

## More

- **Feedback:** 🏃 → **Settings… → Send Feedback…**, or [open an issue](https://github.com/dzgnnl/TomTomSync/issues/new?template=feedback.yml).
- [Technical documentation](docs/DEVELOPMENT.md): building from source, command line, releases, protocol
- [Roadmap](docs/ROADMAP.md) · [Credits](CREDITS.md) · [Security](SECURITY.md) · [MIT License](LICENSE)

Built on the reverse engineering of Jorgen van der Velde
([TomTomWatch](https://github.com/scubajorgen/TomTomWatch)) and Ryan Binns
([ttwatch](https://github.com/ryanbinns/ttwatch)).
TomTom, Strava, Garmin and FIT are trademarks of their owners.
