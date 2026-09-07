# Changelog

## 0.2.0

Security and release engineering pass.

### Security

- The recovery PIN now uses PBKDF2-HMAC-SHA256 at 600,000 rounds instead of a
  hand-written SHA-256 chain at 40,000 rounds. Existing PINs verify in the old
  format once and are then upgraded in place.
- Minimum PIN length raised from 4 to 6 digits. With the new derivation this
  takes an offline guessing attack against a recovered record from roughly two
  minutes to over a day of single-core work.
- The Keychain item is now restricted to this application. Previously any
  program running as the same user could read it silently. Builds with a
  provisioning profile use the data protection Keychain and such a read is
  refused outright; otherwise an access control list forces an approval prompt.
- PIN entry is rate limited: five attempts, then 30 seconds doubling to a
  one-hour maximum.
- Builds use the hardened runtime and a Developer ID signature, with optional
  notarization.

### Reliability

- Launch at Login installs a login agent that restarts protection if the process
  crashes or is force quit. An authenticated quit still stops it.
- Launching at login no longer opens the settings window.

### Performance

- The settings window is built only when first shown, cutting idle memory
  footprint from 19 MB to under 10 MB.
- Protected-app lookups on the activation path are constant time, table rows are
  recycled, and application icons are cached.

### Build and packaging

- Added an Xcode project generated from `project.yml` alongside the existing
  command-line build. Both produce the same bundle; Xcode archives are universal.
- Added `scripts/verify-app.sh`, which checks a built bundle after signing.
- The app has an icon, on the standard macOS rounded shape, using the same shield
  glyph as the menu bar item.
- Fixed all static analyzer warnings and removed the blanket
  `-Wno-deprecated-declarations` suppression.

## 0.1.2

- Authentication presents an interaction shield across every connected display,
  preventing clicks from reaching the protected app.
- The authentication panel stays above the shield until Touch ID, PIN, or Cancel
  is selected.
- Protected apps are immediately re-hidden if they attempt to activate or unhide
  while authentication is pending.

## 0.1.1

- A newly launched protected-app process can no longer inherit the previous
  process's temporary unlock.
- Protected-app termination immediately clears its authorization and cancels any
  pending prompt for that process.
- Recovery PIN storage uses the standard per-user Keychain, fixing error `-34018`
  in locally signed builds.

## 0.1.0

- Initial release.
