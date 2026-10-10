# TomTomSync

Native macOS sync for TomTom sports watches (Spark, Runner 2/3, Adventurer, Multi-Sport).
The USB protocol and ttbin format are ported from [TomTomWatch](https://github.com/scubajorgen/TomTomWatch)
(Java) and [ttwatch](https://github.com/ryanbinns/ttwatch).

The watch is a vendor-defined USB HID device. TomTomSync talks to it through IOKit's
`IOHIDDevice` API, so it needs **no root, no libusb and no kernel-driver detaching**.

## Build

```sh
scripts/build-app.sh --install   # menu bar app → ~/Applications/TomTomSync.app, CLI → build/ttsync
```

## Menu bar app

TomTomSync sits in the menu bar. When the watch is plugged in it exports new
activities (and deletes them from the watch), updates GPS QuickFix, sets the
watch time zone and uploads new activities to Strava. Every step can be switched
off in Settings. Click the status line to see the sync log.

## Strava

Uses the official Strava API v3 (OAuth 2 + `POST /uploads` with the FIT file).

1. Create an API application at <https://www.strava.com/settings/api>.
   Set **Authorization Callback Domain** to `localhost`.
2. In the app: Settings → Strava → paste Client ID and Client Secret → Connect.
   Or from the CLI: `ttsync strava login --client-id ID --client-secret SECRET`.
3. Uploaded files are tracked in `~/TomTom/strava-uploads.json`; Strava also
   rejects duplicates itself, which is treated as "already uploaded".

Tokens are stored in `~/Library/Application Support/TomTomSync/strava.json`
(mode 0600), shared by the app and the CLI.

## Commands

| Command | What it does |
|---|---|
| `ttsync info` | Model, firmware, watch clock, time zone offset, file counts |
| `ttsync export [--delete] [--out DIR]` | Saves each activity as raw `.ttbin` and `.fit` in `~/TomTom/{ttbin,fit}`. `--delete` erases it from the watch only after the raw file has been written and read back |
| `ttsync quickfix [--days 3\|7\|14]` | Downloads GPS ephemeris from TomTom's (still running) QuickFix server, writes and verifies it, resets the GPS chip |
| `ttsync timesync` | Writes the Mac's UTC offset (incl. DST) into the watch settings (index 169 of file `0x00850000`) |
| `ttsync sync [--delete]` | export + quickfix + timesync, then Strava upload if logged in |
| `ttsync strava login\|status\|upload\|logout` | Strava connection and (backlog) uploads |
| `ttsync convert FILE.ttbin…` | Offline ttbin → FIT |
| `ttsync files`, `ttsync dump ID OUT` | Debug: list and save raw watch files |

## Layout

- `Transport/HIDTransport.swift` — IOKit HID device, synchronous send/receive
- `Protocol/Watch.swift` — packet framing and file operations (open/read/write/delete/list)
- `Protocol/WatchSettings.swift` — settings manifest (utc_offset)
- `TTBin/TTBin.swift` — ttbin parser (GPS, heart rate, laps, treadmill, swim, gym, status)
- `FIT/` — FIT encoder and ttbin→FIT activity conversion
- `Sync/Sync.swift` — export / QuickFix / time sync flows used by the CLI and the future app

## Roadmap

1. ✅ CLI (`ttsync`)
2. ✅ Menu bar app with auto-sync on plug-in
3. ✅ Strava upload
