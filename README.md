# Mac App Lock

[![CI](https://github.com/pracharya2601/MacAppLock/actions/workflows/ci.yml/badge.svg)](https://github.com/pracharya2601/MacAppLock/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)

Lock individual macOS applications behind Touch ID or a recovery PIN.

Mac App Lock runs from the menu bar. When an application you have protected comes
to the front, it is hidden and an authentication panel appears across every
display. Unlock with Touch ID, or with a recovery PIN if Touch ID is unavailable.

Everything stays on your Mac. There is no account, no network access, and no
telemetry.

## Requirements

- macOS 13 or later
- Apple silicon or Intel
- Touch ID configured in System Settings, or a 6–12 digit recovery PIN

## Install

Download `Mac App Lock.app` from the [latest release](../../releases/latest), move
it to `/Applications`, and open it.

1. Set a recovery PIN.
2. Choose **Add Applications** and pick the apps to protect.
3. Enable **Launch at Login** so protection starts automatically.
4. Close the settings window. Mac App Lock keeps running from the lock icon in
   the menu bar.

For a first test, protect Calculator or TextEdit rather than something you need.
Do not protect System Settings until you have confirmed both Touch ID and your
recovery PIN work.

## Relocking

- **When I switch away** — authenticate again every time you leave and return.
- **After 1, 5, or 15 minutes** — stay unlocked for that long.

Sleeping the Mac or leaving the user session clears all temporary unlocks, and so
does quitting the app.

## How it works

Four small pieces:

| | |
|---|---|
| `AppController` | Watches `NSWorkspace` activation notifications, decides whether to hide and prompt, owns the settings window and menu bar item |
| `AuthorizationLedger` | In-memory record of what is currently unlocked, keyed by bundle identifier and validated against process ID and expiry |
| `AuthPanelController` | The authentication panel and the interaction shield covering every display |
| `PINVault` | Recovery PIN derivation and Keychain storage |

The ledger is deliberately memory-only, so a restart relocks everything. An
authorisation is tied to a specific process ID, so relaunching a protected
application cannot inherit an earlier unlock.

## Security

- Touch ID goes through Apple's Local Authentication framework. The app receives
  only success or failure and never sees biometric data.
- The recovery PIN is never stored. A random 16-byte salt and a PBKDF2-HMAC-SHA256
  digest over 600,000 rounds are kept in the Keychain, compared in constant time.
- The Keychain item is restricted to this application. Builds with a provisioning
  profile use the data protection Keychain, where another process is refused
  outright; otherwise an access control list forces an explicit approval prompt.
- PIN entry allows five attempts, then locks out for 30 seconds, doubling to a
  one-hour maximum. Touch ID is unaffected.
- Settings and Quit require authentication once any application is protected.
- Launch at Login installs a login agent that restarts protection if the process
  crashes or is force quit. An authenticated quit still stops it.

Please read [SECURITY.md](SECURITY.md) before relying on this, particularly
**Known limitations**. Mac App Lock is a personal privacy guard, not an
administrator-proof control: anyone who can run code as your user can stop it.

## Building from source

Two equivalent build paths. Both produce the same bundle and share the plists in
`Resources/`.

### Xcode

The project is generated from `project.yml`, so generate it first:

```sh
brew install xcodegen      # once
xcodegen generate
open MacAppLock.xcodeproj
```

Build with ⌘B. The scheme runs `scripts/verify-app.sh` afterwards, which checks
the signature, the bundled login agent, the icon, and that the signed binary
launches and passes its self-tests.

Release with **Product → Archive → Distribute App → Developer ID**, which signs,
notarizes and staples in one flow. Archives are universal.

To put the recovery PIN in the data protection Keychain, add the **Keychain
Sharing** capability under Signing & Capabilities. Xcode provisions the profile
that makes the `keychain-access-groups` entitlement legal at runtime; without that
profile the entitlement causes macOS to kill the app at launch.

### Command line

Needs only the Command Line Tools:

```sh
./scripts/build-app.sh                            # → dist/Mac App Lock.app
./scripts/verify-app.sh "dist/Mac App Lock.app"   # post-signing checks
```

The script signs with the first Developer ID Application identity it finds,
enables the hardened runtime, and refuses to finish if the signed binary cannot
run its own self-tests. With no such identity it falls back to an ad-hoc
signature, which is fine for local use.

Optional environment: `SIGN_IDENTITY`, `PROVISIONING_PROFILE`, and `NOTARIZE=1`
with `NOTARY_PROFILE` (see `scripts/build-app.sh`).

### Tests and artwork

```sh
./.build/MacAppLock --self-test           # derivation, record format, ledger rules
./.build/MacAppLock --keychain-self-test  # Keychain round trip
./scripts/make-icon.sh                    # regenerate Resources/AppIcon.icns
```

## Contributing

Issues and pull requests are welcome. `CLAUDE.md` documents the architecture and
the build traps worth knowing about.

Two things catch people out:

- **Keep both build paths working.** Adding a source file also needs it added to
  the `clang` invocation in `scripts/build-app.sh`; Xcode picks it up from
  `Sources/` automatically, so it is easy to break only the command-line build.
- **The checked-in entitlements expect a provisioning profile.**
  `Resources/MacAppLock.entitlements` requests `keychain-access-groups`, which
  macOS only honours when the bundle embeds a profile authorising it. Build
  without one and the app is killed at launch, exiting with 137 rather than any
  useful error. If you are not set up for that, build with the command-line
  script, which omits the entitlement unless you pass `PROVISIONING_PROFILE`, or
  in Xcode clear **Signing & Capabilities → Keychain Sharing** for local work.

Do not report security issues in a public issue; see [SECURITY.md](SECURITY.md).

## Credits

Originally written by **Parbat Chauhan**, and published here with their
permission. Security hardening, production readiness, packaging and release
engineering by **Prakash Acharya**.

## License

[Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attribution.
