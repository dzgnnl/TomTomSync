# TomTomSync

**Keep using your TomTom sports watch on a modern Mac.**

TomTom closed its MySports service and stopped updating its sync software, but
the watches still work fine. TomTomSync is a small menu bar app for macOS that
takes over MySports Connect's job:

- **Saves your activities** from the watch as `.fit` files, the standard format
  that Strava, Garmin Connect, Runalyze, intervals.icu and others accept. The
  original `.ttbin` files are kept too.
- **Uploads new activities to Strava**, if you want it to. Heart rate, cadence and
  laps are included. When the watch recorded your heart rate recovery, that goes
  into the activity description.
- **Updates GPS QuickFix**, so the watch finds a GPS signal in seconds instead of minutes.
- **Sets the watch's time zone**, including daylight saving time.
- **Optionally clears the watch** after a successful export, so it never runs out of space.

All of this happens automatically when you plug in the watch. It needs no
administrator rights, extra drivers or Java.

> TomTomSync is a hobby project, not made or supported by TomTom, Strava or Garmin.
> It was written without TomTom's specifications. It is used daily, but use it at
> your own risk.

## Which watches work?

| Watch | Status |
|---|---|
| TomTom Spark / Spark 3 (all variants), Runner 2 / Runner 3, Adventurer | Supported; tested on a Spark 3 Music |
| TomTom Multi-Sport / Runner / Multi-Sport Cardio (first generation) | Should work, not tested yet |

You need a Mac with **macOS 14 Sonoma or newer** (Apple Silicon or Intel) and
the watch's USB cradle.

## Install

There is no ready-made download yet (see [Distributing](#distributing-a-ready-made-app)),
so for now you build the app on your own Mac. It takes about five minutes and
you only type three commands. You don't need to know how to program.

1. **Install Apple's developer tools.** Open the **Terminal** app (Applications →
   Utilities → Terminal), paste this line and press Return:

   ```sh
   xcode-select --install
   ```

   A window appears. Click **Install** and wait until it finishes, which can take
   a few minutes. If it says the tools are already installed, that's fine.

2. **Download TomTomSync.** On this project's GitHub page click the green
   **Code** button, then **Download ZIP**. Double-click the downloaded file to
   unpack it. You now have a `TomTomSync-main` folder in your Downloads folder.

3. **Build and install.** In Terminal, paste these two lines and press Return:

   ```sh
   cd ~/Downloads/TomTomSync-main
   scripts/build-app.sh --install
   ```

   The first build takes a minute or two. When it says
   `Installed to ~/Applications/TomTomSync.app`, you're done.

4. **Start it.** Open your home folder in Finder, then the **Applications** folder
   there (this is not the main Applications folder), and double-click
   **TomTomSync**. A runner icon 🏃 appears in the menu bar at the top right of
   the screen.

5. **Plug in the watch.** The first time, macOS may ask whether to *allow the
   accessory to connect*: click **Allow**. TomTomSync starts syncing about three
   seconds later and shows a notification when it's done.

To start TomTomSync automatically when you log in, click the menu bar icon →
**Settings…** → **Launch at login**.

## Using it

Click the 🏃 icon in the menu bar to see:

- the sync status, with a **Sync** button to sync manually. Click the status
  line to see a detailed log.
- your recent activities. Each one has an **Upload** button, or a **Strava** link
  that opens it on Strava once it has been uploaded.
- **Open Folder**, which shows your exported files.

Your activities are saved in the **TomTom** folder in your home folder:

| Folder | Contents |
|---|---|
| `~/TomTom/fit` | `.fit` files, for uploading anywhere |
| `~/TomTom/ttbin` | the watch's original files, kept as a backup |

Files are named by date, time and sport, for example `2026-10-10_133648_running.fit`.

### Settings

| Setting | What it does | Default |
|---|---|---|
| Sync automatically when the watch is connected | Starts a sync when you plug in the watch | on |
| Delete activities from the watch after export | Removes each activity from the watch, but only after its file has been saved and checked | on |
| Update GPS QuickFix | Downloads fresh satellite data from TomTom and puts it on the watch | on |
| Set watch time zone to this Mac's | Copies your Mac's time zone to the watch | on |
| Upload new activities automatically (Strava) | Uploads each new activity after export | on, once Strava is connected |
| Launch at login | Starts TomTomSync when you log in | off |

Very short recordings (under a minute or under 10 metres) are saved but not uploaded to Strava.

## Connecting Strava

Strava only allows apps to upload through its official API, and every user
needs their own free "API application". You set it up once, in about two minutes:

1. Go to <https://www.strava.com/settings/api> and log in.
2. Fill in the form:
   - **Application Name**: anything, for example `My TomTom watch`
   - **Category**: `Data Importer`
   - **Website**: anything, for example `http://localhost`
   - **Authorization Callback Domain**: `localhost` (this one is important)
3. Click **Create**. You may need to upload an icon; any image will do.
4. Strava now shows your **Client ID** (a number) and **Client Secret** (click
   *show*). Keep this page open.
5. In TomTomSync: menu bar icon → **Settings…** → **Strava**. Paste the Client ID
   and Client Secret and click **Connect to Strava…**.
6. Your browser opens Strava's permission page. Make sure **Upload your activities**
   is ticked and click **Authorize**. The page then says *Connected to Strava*,
   and you can close it.

From now on new activities are uploaded automatically. Older activities that are
already on Strava are recognised as duplicates and are not uploaded twice.

Keep your Client Secret private, like a password.

## Troubleshooting

**The watch isn't detected.**
- Take the watch out of the cradle and click it back in firmly. The cradle contacts
  are fussy; if the watch doesn't show it's charging, it isn't connected.
- Try another USB port or cable, and avoid unpowered hubs.
- Check **System Settings → Privacy & Security → Allow accessories to connect**.
  If you ever clicked *Don't Allow*, set it to *Ask for new accessories* and
  plug the watch in again.
- Quit any other program that talks to the watch, such as an old MySports Connect.

**"TomTomSync cannot be opened" or "Apple could not verify…".** This happens
with a copy built on another Mac or downloaded from the internet. Go to
**System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
You only need to do this once.

**Strava upload fails with "Authorization Error" or similar.** Open Settings, click
**Disconnect Strava**, then connect again. Make sure *Upload your
activities* is ticked on Strava's permission page.

**An activity is missing.** Check `~/TomTom/ttbin`: if the `.ttbin` file is there,
the export worked. Click the status line in the menu for the detailed log.

## Uninstall

1. Quit TomTomSync (menu bar icon → Quit) and delete `~/Applications/TomTomSync.app`.
2. Optionally delete `~/Library/Application Support/TomTomSync` (your Strava login)
   and `~/TomTom` (your exported activities, so keep that one if you want your data).
3. On <https://www.strava.com/settings/apps> you can revoke TomTomSync's access.

## For the technically inclined

### Command line

The build also creates `build/ttsync`, which does everything from Terminal:

| Command | What it does |
|---|---|
| `ttsync info` | Model, firmware, watch clock, time zone, file counts |
| `ttsync export [--delete] [--out DIR]` | Save activities as `.ttbin` + `.fit`. `--delete` removes each from the watch after the saved file has been read back |
| `ttsync quickfix [--days 3\|7\|14]` | Download, write, verify and activate GPS QuickFix |
| `ttsync timesync` | Set the watch's UTC offset to the Mac's |
| `ttsync sync [--delete]` | All of the above, then Strava upload if connected |
| `ttsync strava login\|status\|upload\|logout` | Connect Strava and upload older activities |
| `ttsync convert FILE.ttbin…` | Convert `.ttbin` files to `.fit` offline |
| `ttsync files`, `ttsync dump ID OUT` | Debugging: list or save raw watch files |

The app and the command line tool share their settings, Strava login and export folder.

### Building from source

Requirements: macOS 14+, Swift 6 (Xcode 16 or the Command Line Tools). There are no third-party dependencies.

```sh
swift build                       # debug build
swift test                        # unit tests
scripts/build-app.sh [--install] [--zip]
```

With full Xcode installed the app is a universal binary (Apple Silicon + Intel);
with only the Command Line Tools it is built for your Mac's own architecture.

How the code is organised, how the watch protocol works and what was reverse
engineered are described in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

### Distributing a ready-made app

`scripts/build-app.sh --zip` creates `build/TomTomSync-<version>.zip`, which you
can attach to a GitHub release. Other people can use it today, but because it
is not signed by an Apple-registered developer, macOS blocks it the first time
and they have to click **Open Anyway** (see Troubleshooting).

For a download that opens without warnings you need an
[Apple Developer Program](https://developer.apple.com/programs/) membership
(USD 99/year) and its *Developer ID Application* certificate. The script then
signs and notarizes the app:

```sh
xcrun notarytool store-credentials tomtomsync   # once; asks for Apple ID + app-specific password
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=tomtomsync \
  scripts/build-app.sh --zip
```

## Credits

TomTomSync would not exist without the people who reverse-engineered the TomTom
watches years ago, in particular **Jorgen van der Velde**
([TomTomWatch](https://github.com/scubajorgen/TomTomWatch)) and **Ryan Binns**
([ttwatch](https://github.com/ryanbinns/ttwatch)). See [CREDITS.md](CREDITS.md).

## License

[MIT](LICENSE). Security issues: see [SECURITY.md](SECURITY.md).

TomTom is a trademark of TomTom N.V., Strava of Strava, Inc., and FIT and Garmin of
Garmin Ltd. This project is not affiliated with or endorsed by any of them.
