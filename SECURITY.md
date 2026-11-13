# Security

Report vulnerabilities privately: **Security** tab → **Report a vulnerability**.
Please don't open a public issue.

## What TomTomSync accesses

- **The watch over USB**: it reads and deletes activities, writes GPS QuickFix and
  the time zone, and reads, writes and deletes routes. Activities are deleted only
  after the exported copy has been read back; a watch's routes are saved to the routes
  folder before its first route sync.
- **Network**: `gpsquickfix.services.tomtom.com` (sends no personal data),
  `api.github.com` (daily update check), `nom.telemetrydeck.com` (one anonymous usage
  signal a day, see [Privacy](README.md#privacy)) and `www.strava.com` (only if
  connected). The update check and the usage signal can be turned off in Settings.
  No third-party code.
- **`127.0.0.1:8723`**: runs only during Strava login (at most 5 minutes) to
  receive the OAuth redirect. A random `state` value blocks injected logins.
- **Files**: activities in `~/TomTom/fit` and `~/TomTom/ttbin` (directories 0700;
  newly written files 0600), routes in `~/TomTom/routes` (default permissions).
  Strava credentials are in
  `~/Library/Application Support/TomTomSync/strava.json` (folder 0700, file 0600).

## Known limitations

- **Strava credentials** are in a file, not the Keychain, because unsigned builds
  would cause Keychain prompts after every update. Any process running as your user
  can read it. Disconnecting revokes access at Strava.
- **Exported activities** contain GPS tracks, which can reveal your home location.
- **Releases are not notarized.** They are built by GitHub Actions from the tagged
  source and signed ad hoc. The Homebrew cask removes the quarantine flag, so
  installing from the tap means trusting this repository.
- **Watch data is treated as untrusted.** The parser bounds-checks fields, caps
  processing at 2,000,000 records per file, and is fuzz-tested.
