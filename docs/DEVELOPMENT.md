# Technical documentation

## Build from source

Needs macOS 14+ and Swift 6 (Xcode 16+ or `xcode-select --install`). No third-party dependencies.

```sh
swift build && swift test
scripts/build-app.sh --install   # → /Applications/TomTomSync.app and build/ttsync
                                 #   (~/Applications without admin rights; or set INSTALL_DIR)
```

`build-app.sh` builds a universal binary with full Xcode and a native one with only
the Command Line Tools. `--zip` creates `build/TomTomSync-<version>.zip`.

## Command line

`ttsync` is installed by Homebrew and shares the Strava login, route settings and
`~/TomTom` with the app. The app's Sync switches don't apply to it.

| Command | |
|---|---|
| `ttsync info` | Model, firmware, clock, time zone, file counts |
| `ttsync export [--delete] [--out DIR]` | Save activities as `.ttbin` + `.fit`; `--delete` removes each one after its saved copy is read back |
| `ttsync quickfix [--days 3\|7\|14]` | Update GPS QuickFix |
| `ttsync timesync` | Set the watch's UTC offset to the Mac's |
| `ttsync sync [--delete]` | Export, QuickFix, time zone and routes, then Strava upload |
| `ttsync strava login --client-id ID [--client-secret SECRET]` | Connect to Strava |
| `ttsync strava status\|upload\|logout` | Strava connection and backlog uploads |
| `ttsync routes [list]` | Routes on the watch and in `~/TomTom/routes` |
| `ttsync routes sync [--dry-run] [--no-strava]` | Download starred Strava routes, then make the watch's routes match `~/TomTom/routes` (see [Routes](#routes)) |
| `ttsync routes strava` | Your Strava routes and which ones would be synced |
| `ttsync routes check FILE.gpx…` | Offline: name, length and simplification of GPX files |
| `ttsync convert FILE.ttbin…` | Offline ttbin → FIT |
| `ttsync files`, `ttsync dump ID OUT` | Debugging: list and save raw watch files |

## Releases

Run **Actions → Release → Run workflow** on `main` and enter the version, e.g.
`v0.2.0`. A new version tags `main`'s latest commit; an existing tag must point
to a commit on `main`. The source is built and tested without release
credentials, then separate jobs publish the release and update the cask.

A published version is never replaced: running the workflow again for an existing
release keeps its archive and only rewrites the cask, with the checksum of the
published archive. To ship a fix, release a new version.

The publishing jobs use the GitHub Actions environment `release`. The
`if: github.ref == 'refs/heads/main'` checks live in the workflow file, so a
workflow edited on another branch could drop them; the environment settings
are what actually protect the token. Set up (Settings → Environments):

- `release` → **Deployment branches and tags: Selected branches and tags**,
  add the branch rule `main` and nothing else.
- `TAP_TOKEN` as an **environment secret** of `release`, with no
  repository-level copy (repository secrets are readable from any branch).
- Optional: a required reviewer for an extra approval step.

[`release.yml`](../.github/workflows/release.yml) publishes the GitHub release
and writes the cask (`packaging/homebrew/tomtomsync.rb.in`, via
`scripts/update-cask.sh`) to [dzgnnl/homebrew-tap](https://github.com/dzgnnl/homebrew-tap).
[`ci.yml`](../.github/workflows/ci.yml) tests every push and pull request.

The secret `TAP_TOKEN` is a fine-grained token with **Contents: read and write**
on `homebrew-tap` only, and it expires yearly. If the cask step fails, renew the
token and re-run the job; re-running is safe.

**Usage statistics:** only releases built by this repository's workflow send the
daily signal. The workflow sets `OFFICIAL_BUILD=1`, which `build-app.sh` writes to
Info.plist as `TTSOfficialBuild`; every other build (a local one, a fork's release)
sends nothing and hides the setting. To test the signal from a local build:
`defaults write nl.dzgn.TomTomSync usageTestSignals -bool true`, which sends in
TelemetryDeck's test mode. A fork that wants its own statistics changes the app ID
in [`Telemetry.swift`](../Sources/TomTomKit/Sync/Telemetry.swift).

**Signing:** releases are signed ad hoc. The cask removes the quarantine flag, so
Homebrew users get no Gatekeeper warning; users who download the ZIP directly
click *Open Anyway*. Developer ID signing is on the [roadmap](ROADMAP.md).
`build-app.sh` already supports it:

```sh
SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<notarytool profile> \
  scripts/build-app.sh --zip
```

## Code layout

| Path | |
|---|---|
| `Sources/TomTomKit/Transport` | IOKit HID access |
| `Sources/TomTomKit/Protocol` | Packet framing, file operations, settings manifest |
| `Sources/TomTomKit/TTBin` | ttbin parser, cadence, Strava description |
| `Sources/TomTomKit/FIT` | FIT encoder, ttbin → FIT |
| `Sources/TomTomKit/Sync` | Export, QuickFix, time sync, `SyncRunner` (shared by app and CLI), update check, usage signal |
| `Sources/TomTomKit/Routes` | GPX, simplification, route file (protobuf), folder → watch sync |
| `Sources/TomTomKit/Strava` | OAuth (loopback redirect + `state`), upload, upload ledger |
| `Sources/ttsync`, `Sources/TomTomSyncApp` | CLI; SwiftUI menu bar app |
| `Tests/TomTomKitTests` | Unit and fuzz tests on synthetic data (ttbin, routes, Strava routes, update check, usage signal) |

## USB protocol

The watches are USB HID devices with vendor ID `0x1390`. TomTomSync uses
`IOHIDDevice`, so it needs no root, libusb or driver detaching.

| Product ID | Watches | Packet / read / write size |
|---|---|---|
| `0x7474` | Multi-Sport, Runner, Multi-Sport Cardio | 64 / 50 / 54 |
| `0x7475` | Spark, Spark Music, Runner 2/3 (Music), Adventurer | 256 / 242 / 246 |
| `0x7477` | Spark Cardio, Runner 2/3 Cardio | 256 / 242 / 246 |

Packets are `[0x09, len+2, counter, msg, payload…]`; the reply starts with `0x01`
instead. Payload integers are big-endian; the product ID reply is little-endian.
File-operation errors are at payload offset 16. Startup sequence:
`0d 0a 22 22 20 0a 28 28 1f`.

| Msg | Meaning |
|---|---|
| `02` / `06` / `0c` | open for write / open for read / close |
| `03` | delete |
| `04` / `07` (reply `09`) | write / read data |
| `05` | file size (offset 12) |
| `11` / `12` / `0a` | find first / find next / find close |
| `14` | watch time (u32 UTC) |
| `1d` | reset GPS processor |
| `20` / `21` / `28` | product ID / firmware / BLE version |

| File | Contents |
|---|---|
| `0x0091xxxx` | Activities (ttbin) |
| `0x00010100` | GPS QuickFix: download `https://gpsquickfix.services.tomtom.com/fitness/sifgps.f2p{3,7,14}enc.ee`, write it, verify it, then send `1d` |
| `0x00850000` | Settings, little-endian: `u16 type, u16 count, {u16 index, u32 value}…`; index 169 = UTC offset in seconds |
| `0x00B80000`–`0x00B8000E` | Routes ("trails"), one per file; see [Routes](#routes) |

## ttbin format

The header (tag `0x20`) holds the version, firmware, product ID, local start time,
UTC offset and a record-length table per tag. A length includes the tag;
`0xFFFF` means a u16 length follows. Little-endian. **GPS times are UTC; all other
times are local** (UTC = local − offset).

| Tag | Record | Fields (offset) |
|---|---|---|
| `21` | Status | status 0 (1 active, 2 paused, 3 stopped), sport 1, time 2 |
| `22` | GPS | lat 0, lon 4 (i32/1e7), speed 10 (cm/s), time 12, calories 16, distance 22 (f32), steps this second 26 |
| `25` | Heart rate | bpm 0, time 2 |
| `27` | Summary | sport 0, distance 1 (f32), duration 5, calories 9 |
| `2f` | Lap | time 0, distance 4 (f32), calories 8 |
| `32` / `34` / `41` | Treadmill / swim / gym | time, distance, calories |
| `3f` | HR recovery | score 0, bpm drop after 1 min 4 (i32); written only if paused for that minute |
| `4a` | Fitness points | u16 at 6 |

## FIT output

Messages: `file_id` (manufacturer 71 = TomTom), `device_info`, timer events, one
`record` per second, `lap`, `session` and `activity`, plus a `recovery_hr` event
when the watch recorded one. Running cadence is written in strides/min (steps ÷ 2),
smoothed over 20 s.

To validate a file: `pip install garmin-fit-sdk`, then
`Decoder(Stream.from_file(path)).read()` should return no errors.

## Routes

Meant for Runner 3, Spark 3 and Adventurer. First-generation watches and the original
Spark Music (product ID `0x07D5`, no Trails menu) are skipped; other product IDs are
assumed to support routes. A watch can't be asked: the original Spark Music accepts a
route file without an error and returns it unchanged, it just has no menu to show it.
That is why route sync is off by default (`routeSync` in the app's preferences; for
`ttsync sync` without the app: `defaults write nl.dzgn.TomTomSync routeSync -bool true`).
`ttsync routes sync` works regardless of the setting.

### Sync

`~/TomTom/routes/*.gpx` (own files) and `~/TomTom/routes/Strava/*.gpx` are mirrored
to the watch as part of every sync (Settings → Routes, or `ttsync routes sync`):

1. **Selection:** at most 15 routes. Own files go first, then Strava, each newest
   first (file creation date). An exact duplicate (same name and points) takes one
   slot, and the own copy wins. Routes that don't fit are reported.
2. **Order:** on the watch, the routes are sorted by name, in slots `0x00B80000` upward.
   A slot that already holds the same route is left alone. Other slots are deleted
   and rewritten, and route files beyond the last slot are deleted.
3. **First sync of a watch:** its routes that aren't in the folder are saved there as
   GPX first, so nothing is lost. The raw route files are also copied to
   `routes/.watch-backup-<serial>/`. A marker file `routes/.imported-<serial>`
   records that this has been done. The serial is reduced to letters, digits, `-`
   and `_`, plus a short hash if that changed it. A watch that reports no serial
   never gets a marker, so its unknown routes are saved on every sync.
4. **Unreadable route files:** on any sync, if a route file on the watch can't be decoded,
   it is copied to the backup folder and the route sync stops, so it is never
   overwritten or deleted. The same goes for the folder: if a GPX file or the folder
   itself can't be read, the route sync stops and leaves the watch unchanged. A missing
   folder counts as empty.

**Strava** (`Routes/StravaRoutes.swift`), before connecting to the watch:
- `GET /athletes/{id}/routes` lists the athlete's own routes, page by page until an
  empty page (Strava can return short pages before the end). Saving someone else's
  route on Strava makes a copy, so it shows up here too. Starred routes of the
  chosen kinds are kept, newest first, 15 at most.
- Kinds map Strava route types as follows: run = 2 Run, 5 Trail Run; walk = 3 Walk, 4 Hike;
  ride = 1 Ride, 6 Gravel, 7 MTB. Default: run.
- Changed routes are downloaded with `GET /routes/{id}/export_gpx`, using
  `updated_at`. The file's creation date is set to the route's `created_at`.
- `routes/Strava/.index.json` maps route IDs to files. Only those files are ever
  replaced or removed, e.g. when a route is unstarred.
- Private routes need the `read_all` scope, requested since v0.2.0. Older logins
  have to reconnect.
- The settings (`routeSync`, `stravaRouteKinds`) live in the app's preferences
  domain `nl.dzgn.TomTomSync`, so `ttsync` uses the same ones.

**GPX:** tracks (`trkseg` → segment) and routes (`rte` → segment) are read.
Waypoints, elevation and times are ignored. The name comes from the first `trk` or
`rte`, then `metadata`, then the file name. On the watch the name is reduced to
ASCII and 32 characters.

**Simplification:** routes over 500 points are reduced with Douglas-Peucker,
ranked to reach an exact point count:
- Each point's importance is its distance to the chord at the step where
  Douglas-Peucker would keep it, capped at its parent's importance. Segment ends are always kept.
- The 500 most important points over all segments are kept.
- Distances use a local equirectangular projection, measured to the chord segment
  rather than the infinite line, so the tips of out-and-back sections stay.
- The reported deviation is measured afterwards, between every removed point and
  the simplified line.

### Route file format

Protobuf (proto2 wire format), described from the files TomTom MySports wrote. Field
numbers are given as `#n`. Coordinates are `LatLon = { #1 fixed32 }`, degrees × 10⁷ as
a signed 32-bit value, and `Coordinate = { #1 LatLon lat, #2 LatLon lon }`.

- The root is two `#1` messages:
  1. `{ #7 { #1 fixed32 0x1234DAEB, #2 fixed32 0x00070100 } }`: file header.
  2. `{ #8 { #1 Track } }`: the route itself.
- `Track`:
  - `#1` info: `{ #1 string name, #2 bounding box, #3 bytes time }`.
    - The bounding box is `{ #1 min lat, #2 min lon, #3 max lat, #4 max lon }`, each a `LatLon`.
    - The time is 16 bytes: zero, then a big-endian u64 at offset 8 holding seconds
      since 2016-03-07 06:29:57 UTC × 3.45559 (the origin and rate are empirical).
  - `#2`, twice: `{ #1 Coordinate, #2 int32 index }`. The first and last point of the
    first segment, with index 1 and 2.
  - `#3` segments: `{ #1 int32 segment count, #2 segment… }`. Each segment is
    `{ #1 int32 point count, #2 { #1 Coordinate }… }`.

There is no index file: the watch lists whatever `0x00B8xxxx` files exist. MySports
limited routes to 500 points; whether the watch enforces that is untested.
Credit: the layout was first worked out by
[TomTomWatch](https://github.com/scubajorgen/TomTomWatch).
