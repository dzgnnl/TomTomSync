# Security

## Reporting a vulnerability

Please report security problems privately through GitHub: on this repository's
**Security** tab, click **Report a vulnerability**. Please don't open a public issue.

## What TomTomSync accesses

| What | Why |
|---|---|
| The TomTom watch over USB (IOKit HID, vendor ID `0x1390`) | Reading and deleting activities, writing GPS QuickFix data and the time zone setting |
| `https://gpsquickfix.services.tomtom.com` | Downloading GPS QuickFix data (no account or personal data sent) |
| `https://www.strava.com` | Login and uploads, only when you connect Strava |
| `127.0.0.1:8723` | A local web server that runs only while you connect Strava, to receive the browser's login redirect |
| `~/TomTom` | Exported activities and the record of Strava uploads |
| `~/Library/Application Support/TomTomSync/strava.json` | Your Strava Client ID and Secret and the login tokens |

TomTomSync has no analytics or telemetry, contacts no other servers and uses no
third-party code.

## Design notes and known limitations

- **Strava credentials** are stored in a JSON file that only your user account can
  read (folder `0700`, file `0600`), not in the macOS Keychain. Self-built apps
  have no stable code signature, so the Keychain would ask for your password after
  every rebuild. Any program running under your account can read this file.
  Disconnecting Strava revokes TomTomSync's access at Strava and removes the tokens.
  You can also revoke access at <https://www.strava.com/settings/apps>.
- **Strava login** uses OAuth 2 with a random `state` value, checked on the
  redirect, so other programs or web pages cannot inject their own login. The
  redirect server listens only on the loopback address, and only during login
  (at most 5 minutes).
- **Each user creates their own Strava API application.** No shared client secret
  is built into the app.
- **Exported activities** contain GPS tracks, which can reveal where you live.
  They are stored in your home folder with normal permissions.
- **Watch data is treated as untrusted.** The ttbin parser checks every length and
  offset and is fuzz-tested with truncated and corrupted files.
- **Writing to the watch.** TomTomSync writes only the GPS QuickFix file (read back
  and verified before the GPS chip is reset) and the time zone value in the settings
  file. Activities are deleted only after the exported copy has been written and read
  back. The command-line debugging commands can do more; use them with care.
- **Unsigned builds.** Releases are built by GitHub Actions from the tagged
  source, but are not yet signed with an Apple Developer ID or notarized. The
  Homebrew cask removes macOS's quarantine flag so the app can open; by installing
  from the tap you trust this repository's releases. Only download builds from this
  repository's Releases page or the `dzgnnl/tap` Homebrew tap, or build the app
  yourself.
