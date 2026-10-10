# Roadmap and open issues

## Open

### Apple Developer ID signing and notarization
*Only if there is enough interest: it needs an Apple Developer Program membership (USD 99/year).*

What it would give:
- downloads from the Releases page open without a Gatekeeper warning
- a submission to the official `homebrew/cask`, so `brew install --cask tomtomsync`
  without the tap
- a stable code signature, so the Strava login can move to the Keychain without
  password prompts after every update (see [SECURITY.md](../SECURITY.md))
- a basis for automatic in-app updates with [Sparkle](https://sparkle-project.org),
  with updates signed by its own EdDSA key

The build script already supports it ([RELEASING.md](RELEASING.md)); what remains
is the account, the CI secrets and, optionally, Sparkle.

### Device names on Strava
Strava shows a generic "TomTom GPS Watch". Each product ID (e.g. 2005) needs
its confirmed model name, and ideally the FIT product numbers that TomTom
MySports used.

### Testing on more watches
Only the Spark 3 Music (USB product ID `0x7475`) has been tested. Multi-Sport /
Runner (`0x7474`, 64-byte packets) and Spark Cardio (`0x7477`) need testing.

### Default for "delete after export"
It's on by default. Consider off by default for new users.

### Relaunch after `brew upgrade`
Upgrading quits the app; the user has to start it again.

## Possible later features

TomTomWatch supports these, but TomTomSync doesn't yet:
- GPX export
- route upload
- workouts and races
- activity tracking (steps/sleep)
- watch preferences
