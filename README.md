# TomTomSync

Native macOS sync for TomTom sports watches (Spark, Runner 2/3, Adventurer, Multi-Sport).
The USB protocol and ttbin format are ported from [TomTomWatch](https://github.com/scubajorgen/TomTomWatch)
(Java) and [ttwatch](https://github.com/ryanbinns/ttwatch).

The watch is a vendor-defined USB HID device. TomTomSync talks to it through IOKit's
`IOHIDDevice` API, so it needs **no root, no libusb and no kernel-driver detaching**.

## Build

```sh
swift build -c release
.build/release/ttsync help
```

## Commands

| Command | What it does |
|---|---|
| `ttsync info` | Model, firmware, watch clock, time zone offset, file counts |
| `ttsync export [--delete] [--out DIR]` | Saves each activity as raw `.ttbin` and `.fit` in `~/TomTom/{ttbin,fit}`. `--delete` erases it from the watch only after the raw file has been written and read back |
| `ttsync quickfix [--days 3\|7\|14]` | Downloads GPS ephemeris from TomTom's (still running) QuickFix server, writes and verifies it, resets the GPS chip |
| `ttsync timesync` | Writes the Mac's UTC offset (incl. DST) into the watch settings (index 169 of file `0x00850000`) |
| `ttsync sync [--delete]` | export + quickfix + timesync |
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
2. Menu bar app: auto-sync when the watch is plugged in
3. Strava upload (OAuth + `/uploads` with the FIT file)
