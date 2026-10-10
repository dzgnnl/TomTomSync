# Technical documentation

## Build from source

Needs macOS 14+ and Swift 6 (Xcode 16+ or `xcode-select --install`). No third-party dependencies.

```sh
swift build && swift test
scripts/build-app.sh --install   # → ~/Applications/TomTomSync.app and build/ttsync
```

`build-app.sh` builds a universal binary with full Xcode and a native one with only
the Command Line Tools. `--zip` creates `build/TomTomSync-<version>.zip`.

## Command line

`ttsync` is installed by Homebrew and shares settings, Strava login and `~/TomTom` with the app.

| Command | |
|---|---|
| `ttsync info` | Model, firmware, clock, time zone, file counts |
| `ttsync export [--delete] [--out DIR]` | Save activities as `.ttbin` + `.fit`; `--delete` removes each one after its saved copy is read back |
| `ttsync quickfix [--days 3\|7\|14]` | Update GPS QuickFix |
| `ttsync timesync` | Set the watch's UTC offset to the Mac's |
| `ttsync sync [--delete]` | All of the above, then Strava upload |
| `ttsync strava login\|status\|upload\|logout` | Strava connection and backlog uploads |
| `ttsync convert FILE.ttbin…` | Offline ttbin → FIT |
| `ttsync files`, `ttsync dump ID OUT` | Debugging: list and save raw watch files |

## Releases

```sh
git tag v0.2.0 && git push origin v0.2.0
```

[`release.yml`](../.github/workflows/release.yml) tests and builds the app,
publishes the GitHub release, and writes the cask
(`packaging/homebrew/tomtomsync.rb.in`, via `scripts/update-cask.sh`) to
[dzgnnl/homebrew-tap](https://github.com/dzgnnl/homebrew-tap).
[`ci.yml`](../.github/workflows/ci.yml) tests every push and pull request.

The secret `TAP_TOKEN` is a fine-grained token with **Contents: read and write**
on `homebrew-tap` only, and it expires yearly. If the cask step fails, renew the
token and re-run the job; re-running is safe.

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
| `Sources/TomTomKit/Sync` | Export, QuickFix, time sync, `SyncRunner` (shared by app and CLI) |
| `Sources/TomTomKit/Strava` | OAuth (loopback redirect + `state`), upload, upload ledger |
| `Sources/ttsync`, `Sources/TomTomSyncApp` | CLI; SwiftUI menu bar app |
| `Tests/TomTomKitTests` | Unit and fuzz tests on synthetic ttbin data |

## USB protocol

The watches are USB HID devices with vendor ID `0x1390`. TomTomSync uses
`IOHIDDevice`, so it needs no root, libusb or driver detaching.

| Product ID | Watches | Packet / read / write size |
|---|---|---|
| `0x7474` | Multi-Sport, Runner, Multi-Sport Cardio | 64 / 50 / 54 |
| `0x7475` | Spark, Spark Music, Runner 2/3, Adventurer | 256 / 242 / 246 |
| `0x7477` | Spark Cardio | 256 / 242 / 246 |

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
