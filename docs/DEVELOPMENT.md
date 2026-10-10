# Development notes

## Code layout

| Path | Contents |
|---|---|
| `Sources/TomTomKit/Transport/HIDTransport.swift` | IOKit HID device access, synchronous send/receive on a private run loop thread |
| `Sources/TomTomKit/Protocol/Watch.swift` | Packet framing, startup sequence, file operations (list/read/write/delete), device info |
| `Sources/TomTomKit/Protocol/WatchSettings.swift` | Settings manifest (`0x00850000`) parser/writer |
| `Sources/TomTomKit/TTBin/` | ttbin parser, derived values (cadence, Strava description) |
| `Sources/TomTomKit/FIT/` | Minimal FIT encoder and ttbin → FIT activity conversion |
| `Sources/TomTomKit/Sync/Sync.swift` | Export, QuickFix, time sync and `SyncRunner`, shared by the app and the CLI |
| `Sources/TomTomKit/Strava/Strava.swift` | Strava API v3: OAuth with a loopback redirect, upload, upload ledger |
| `Sources/ttsync/` | Command-line tool |
| `Sources/TomTomSyncApp/` | SwiftUI menu bar app (`MenuBarExtra`), plug-in detection, settings |
| `Tests/TomTomKitTests/` | Unit tests; ttbin files are generated synthetically, no real recordings |
| `scripts/build-app.sh` | Builds, signs (ad hoc or Developer ID), zips and installs the app bundle |

## USB

The watches are vendor-defined USB HID devices with vendor ID `0x1390`:

| Product ID | Watches | Packet size |
|---|---|---|
| `0x7474` | Multi-Sport, Runner, Multi-Sport Cardio | 64 |
| `0x7475` | Spark, Spark Music, Runner 2/3, Adventurer | 256 |
| `0x7477` | Spark Cardio | 256 |

Because the macOS HID manager already owns the device, TomTomSync talks to it
through `IOHIDDevice` (output reports out, input report callback in). That needs
no root, libusb or kernel driver detaching, unlike the libusb/usb4java approach.

Packets:

```
request:  [0x09, len+2, counter, message, payload…]
response: [0x01, len+2, counter, message, payload…]
```

Integers in payloads are big-endian. The exception is the product ID reply,
which is little-endian.

| Message | Meaning |
|---|---|
| `0x02` / `0x06` / `0x0c` | open file for write / open for read / close |
| `0x03` | delete file |
| `0x04` / `0x07` (reply `0x09`) | write data / read data |
| `0x05` | file size (at payload offset 12) |
| `0x11` / `0x12` / `0x0a` | find first / find next / find close (file listing) |
| `0x14` | watch time (u32 UTC) |
| `0x1d` | reset GPS processor |
| `0x20` / `0x21` / `0x28` | product ID / firmware version / BLE version |

The startup sequence is `0x0d 0x0a 0x22 0x22 0x20 0x0a 0x28 0x28 0x1f`. File
operation errors are at payload offset 16. Read chunks are 242 bytes (50 on
`0x7474`) and write chunks 246 (54).

### Files

| File ID | Contents |
|---|---|
| `0x0091xxxx` | Activities (ttbin) |
| `0x00010100` | GPS QuickFix ephemeris |
| `0x00850000` | Settings manifest: LE `u16 type, u16 count, {u16 index, u32 value}…`; index 169 = UTC offset in seconds (signed) |
| `0x00f20000` | Preferences XML |

GPS QuickFix data is still served daily at
`https://gpsquickfix.services.tomtom.com/fitness/sifgps.f2p{3,7,14}enc.ee`.
To install it: write it to `0x00010100`, read it back to verify, then send `0x1d`.

## ttbin

The header begins with tag `0x20`, file version, firmware, product ID and local
start time, followed by the watch time, local UTC offset and a table of record
lengths per tag. A length includes the tag byte; `0xFFFF` means a u16 length
follows the tag. Integers are little-endian.

**GPS records are UTC; every other timestamp is local time**, so
UTC = local − header offset.

| Tag | Record | Fields used (offset in record body) |
|---|---|---|
| `0x21` | Status | status 0 (0 ready, 1 active, 2 paused, 3 stopped), sport 1, time 2 |
| `0x22` | GPS (28 bytes) | lat 0, lon 4 (i32 / 1e7), heading 8, speed 10 (cm/s), time 12, calories 16, instant speed 18 (f32), distance 22 (f32), steps in this second 26 |
| `0x25` | Heart rate | bpm 0, time 2 |
| `0x27` | Summary | sport 0, distance 1 (f32), duration 5, calories 9 |
| `0x2f` | Lap | total time 0, distance 4 (f32), calories 8 |
| `0x32` / `0x34` / `0x41` | Treadmill / swim / gym | time, distance, calories |
| `0x3f` | Heart rate recovery | score 0 (i32), drop in bpm after 1 minute 4 (i32). Only written if the activity stays paused for that minute |
| `0x4a` | Fitness points | points at 6 (u16) |
| `0x4b` | Fitness state (protobuf) | not used |

## FIT output

The encoder writes `file_id` (manufacturer 71 = TomTom, product = ttbin product
ID, product name), `device_info`, timer start/stop `event`s, one `record` per second
(position, distance, speed, heart rate, calories, cadence), `lap`, `session` and
`activity`. When there is a heart rate recovery value, it is added as a
`recovery_hr` event.

Running cadence in FIT is in strides per minute (steps ÷ 2) with a 1/128
fractional field. Strava doubles it back for runs. The per-second step count
(2 or 3) is smoothed over 20 seconds.

To check the output against Garmin's decoder:

```sh
python3 -m venv venv && venv/bin/pip install garmin-fit-sdk
venv/bin/python - <<'EOF'
from garmin_fit_sdk import Decoder, Stream
messages, errors = Decoder(Stream.from_file("activity.fit")).read()
print(errors, {k: len(v) for k, v in messages.items()})
EOF
```

## Strava

Uses the API v3 authorization code flow with the redirect
`http://localhost:8723/callback`. A one-shot `NWListener` on `127.0.0.1` accepts the
redirect and checks the `state` value. Uploads go to `POST /uploads` with
`data_type=fit` and the file name as `external_id`, then the client polls
`GET /uploads/{id}`. An upload rejected as "duplicate of …/activities/N" counts
as already uploaded. Successful uploads are recorded in `~/TomTom/strava-uploads.json`.

## Not yet done

- Proper model names for each product ID (Strava currently shows a generic name)
- Testing on first-generation (`0x7474`) watches
- Workouts, routes, races and watch preferences, which TomTomWatch supports
