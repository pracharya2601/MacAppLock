# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> Note: `../CLAUDE.md` (in `~/Downloads`) describes an unrelated project ("CaseScribe") and does not
> apply here. Ignore it while working in this repository.

## Project

Mac App Lock — a menu-bar-only (`LSUIElement`) macOS agent, written in Objective-C with ARC against
raw AppKit. It gates user-selected applications behind Touch ID or a recovery PIN. No Xcode project,
no `Package.swift`, no third-party dependencies, no nibs or storyboards — every view is built
programmatically. Minimum target is macOS 13 (uses `SMAppService`, SF Symbols).

## Commands

There are **two build paths that must stay equivalent**. Both consume the same checked-in
`Resources/Info.plist`, `Resources/com.prakashacharya.MacAppLock.agent.plist`, and
`Resources/MacAppLock.entitlements`, so changing bundle metadata means editing those files, not
either build system.

```sh
./scripts/make-icon.sh                 # regenerate Resources/AppIcon.icns (artwork only)
xcodegen generate                      # regenerate MacAppLock.xcodeproj from project.yml
xcodebuild -project MacAppLock.xcodeproj -scheme MacAppLock -configuration Release build

./scripts/build-app.sh                 # → dist/Mac App Lock.app
./scripts/build-app.sh /tmp/stage      # optional output root

./scripts/verify-app.sh "dist/Mac App Lock.app"   # post-signing checks
```

`MacAppLock.xcodeproj` is **generated and disposable** — never hand-edit it. `project.yml` is the
source of truth; regenerate after changing it. Xcode builds are universal (x86_64 + arm64);
`build-app.sh` builds for the host architecture only.

Run the regression tests — the binary is its own test runner, there is no test framework:

```sh
./.build/MacAppLock --self-test            # PINVault + AuthorizationLedger pure logic
./.build/MacAppLock --keychain-self-test   # real Keychain add/read/delete round trip
```

`.build/MacAppLock` is produced as a side effect of `build-app.sh`, so build first. To run a single
test, call the corresponding `+ runSelfTest` / `+ runKeychainSelfTest` class method — the two flags in
`Sources/main.m:11` are the only granularity that exists. New tests are added as a `+ (BOOL)runSelfTest`
on the class under test and wired into `main.m`.

Run the built agent for manual testing (it has no dock icon; quit from the menu-bar lock icon):

```sh
open "dist/Mac App Lock.app"
```

### Build-system traps already hit here

Three of these cost real debugging time; do not re-litigate them:

- **Verification cannot be a build phase.** Xcode signs *after* every build phase completes, so a
  script phase only ever sees an unsigned binary — and an unsigned arm64 binary is SIGKILLed
  (exit 137) the moment it runs. That is why `scripts/verify-app.sh` is a **scheme post-action**,
  not a `postBuildScripts` entry.
- **`FULL_PRODUCT_NAME` cannot split the bundle name from the executable name.** Setting it is
  honoured in build settings but ignored by the build system, so the product lands at
  `MacAppLock.app` while scripts look for `Mac App Lock.app`. `PRODUCT_NAME` drives both; the
  executable is therefore `Contents/MacOS/Mac App Lock`, with a space, and the login agent's
  `BundleProgram` must match.
- **`keychain-access-groups` requires an embedded provisioning profile.** Without one AMFI
  SIGKILLs the app at launch. In Xcode, adding the Keychain Sharing capability provisions it; from
  the shell, pass `PROVISIONING_PROFILE=...`.
- **Once that entitlement is present, a file-Keychain query also matches data protection items.**
  The two backends stop being independent. `storeData:account:` therefore clears both backends
  *before* writing and never after — purging the "legacy" copy post-write deletes the value just
  stored, which silently breaks PIN storage in entitled builds only.
- **Xcode edits are lost on regeneration.** Changing the bundle identifier or capabilities in the
  Xcode UI writes to `MacAppLock.xcodeproj` (disposable) and to `Resources/MacAppLock.entitlements`
  (kept). Mirror any such change into `project.yml`, or the next `xcodegen generate` reverts it and
  breaks the provisioning match. Xcode also rewrites `Resources/Info.plist` to use build variables
  such as `$(PRODUCT_BUNDLE_IDENTIFIER)`; `build-app.sh` expands those itself, since a plain copy
  would ship the literal string.

Signing, notarization, and the provisioning-profile path are described in
`README.md`. Two build-script behaviours matter when changing code:

- The script runs `--self-test` twice: once on the raw binary and once on the
  **signed** bundle. The second run exists because AMFI SIGKILLs a process that
  claims a restricted entitlement without an embedded provisioning profile, and
  `codesign --verify` does not catch that. If a build starts failing with exit
  137, that is the cause.
- `keychain-access-groups` is only requested when `PROVISIONING_PROFILE` is set.
  Adding it unconditionally kills the app at launch.

### Things the build script owns

`scripts/build-app.sh` is the whole build system. When changing the project you will likely edit it:

- **Adding a source file** requires appending it to the explicit `.m` list passed to `clang`.
  Xcode picks it up automatically from `Sources/`, so it is easy to add one and break only the
  shell build — build both before calling it done.
- **Adding a framework** requires a new `-framework` flag *and* a `dependencies:` entry in
  `project.yml`.
- **Version bumps** live in `Resources/Info.plist` (`CFBundleShortVersionString` /
  `CFBundleVersion`), shared by both build paths, with a matching `## Version X.Y.Z` section
  appended to `README.md`.
- The bundle is signed with the first **Developer ID Application** identity found, using the
  hardened runtime, falling back to ad-hoc only when no such identity exists. `xattr -cr` runs
  twice, before and on retry after signing, because the repo lives under a File-Provider-synced
  folder that reattaches Finder metadata mid-build.
- Launch at Login uses `SMAppService agentServiceWithPlistName:` against the agent plist the
  script generates into `Contents/Library/LaunchAgents/`. It only registers successfully when the
  app is in `/Applications`; testing it from `dist/` will fail. The agent sets
  `KeepAlive/SuccessfulExit=false`, so a crash restarts protection but an authenticated quit
  (a clean `exit(0)`) does not.

`dist/`, `dist-0.1.1/`, `packaged-Mac-App-Lock.app/`, the `previous-*.zip` files and the empty
`.build/{artifacts,checkouts,repositories}` directories are stale build output, not inputs.

## Architecture

`main.m` either runs a self-test and exits, or constructs `AppController` as the `NSApplication`
delegate. Four classes, one responsibility each:

- **`AppController`** — everything stateful: the settings window, the status-bar menu, `NSUserDefaults`
  persistence, the `NSWorkspace` observers, and the lock/unlock decision logic.
- **`AuthorizationLedger`** — in-memory record of which apps are currently unlocked.
- **`AuthPanelController`** — the modal authentication surface (shield windows + panel + `LAContext` +
  PIN entry).
- **`PINVault`** — recovery-PIN derivation and Keychain storage.

### How locking actually works

There is no privileged helper or system extension. `AppController` subscribes to
`NSWorkspaceDidActivateApplicationNotification` / `DidUnhide` / `DidDeactivate` / `DidTerminate` and,
when a protected bundle identifier activates without a valid authorization, calls `[application hide]`
and presents the auth panel. This is reactive, so a protected app is briefly visible before macOS
delivers the notification — a known, documented limitation, not a bug to "fix" without a privileged
component.

`pendingApplication` is the single-slot re-entrancy guard. While it is set, any activate/unhide event
for that app re-hides it and calls `-bringToFront` on the panel instead of starting a second
authentication.

### Authorization invariants (`AuthorizationLedger`)

An authorization is the triple `(bundleIdentifier, processIdentifier, expiry)`, and
`-isAuthorizedBundleIdentifier:processIdentifier:` **revokes on any failed check**. Two invariants the
self-test pins down and that changes must preserve:

- A relaunched protected app has a new pid, so it can never inherit the previous process's unlock.
- Expiry is checked against wall clock; `unlockDurationMinutes == 0` means "relock when I switch away"
  and is implemented as `distantFuture` expiry plus revocation in `-applicationDidDeactivate:`.

Everything is revoked wholesale on sleep, session resign, monitoring being turned off, and duration
changes.

### Authentication surface (`AuthPanelController`)

Reused for three distinct purposes through the same
`-presentForApplicationName:onUnlock:onCancel:` entry point: unlocking a protected app, opening
Settings, and quitting the agent (see `-showSettings` and `-requestQuit:`). Settings and Quit are only
gated once at least one app is protected and authentication is actually possible.

The panel creates one borderless shield window per `NSScreen` at `NSScreenSaverWindowLevel` with the
panel itself one level above, so clicks cannot reach the protected app; shields are rebuilt on
`NSApplicationDidChangeScreenParametersNotification`. `-dismiss` must always tear down the shields —
leaking one locks the user out of their screen.

### PIN storage (`PINVault`)

Records are **versioned by length**, which is what makes migration work:

- **v1** (0.1.2 and earlier): 48 bytes, `salt(16) || digest(32)`, no header. A hand-rolled
  SHA-256 chain at 40 000 rounds. Verify-only; `deriveVersion1PIN:` exists solely to read these.
- **v2** (current): 53 bytes, `version(1) || rounds_be32(4) || salt(16) || digest(32)`,
  PBKDF2-HMAC-SHA256. The round count is stored *in the record*, so raising `PINVaultRounds`
  re-upgrades existing records on next successful verify rather than invalidating them.

A successful v1 verify, or a v2 verify at a lower round count, rewrites the record in place.
Comparison is constant-time. Do not change the v1 derivation or the length constants — they are
the only way old records can still be read.

Storage tries the data protection Keychain first and falls back to the file Keychain with a
`kSecAttrAccess` ACL naming only this app. `kSecAttrAccessible` and `kSecAttrAccess` are mutually
exclusive, hence the branch in `storeData:account:`. The data protection path only works when the
build embeds a provisioning profile; otherwise it returns `-34018` and the fallback runs.

Throttling state lives in a separate Keychain item (`owner-pin-throttle`): five free attempts,
then 30 s doubling to a 1 h cap. It defends the keyboard, not an offline attack — offline cost
comes from the round count and the 6-digit minimum.

### Persistence

`NSUserDefaults` (`protectedApplications` — an array of `{bundleIdentifier, name, path}` dictionaries
keyed and deduplicated by bundle identifier; `monitoringEnabled`; `unlockDuration` ∈ {0, 1, 5, 15}) and
the Keychain for the PIN. Nothing else is written to disk; the ledger is deliberately memory-only so a
restart re-locks everything.

`applicationIndex` is a derived bundle-identifier → entry map, rebuilt by `rebuildApplicationIndex`.
It backs the activation hot path, which runs on **every** app switch system-wide, so keep that path
free of linear scans. Anything that mutates `protectedApplications` must go through
`saveApplications`, which rebuilds the index.

### App icon

`Resources/AppIcon.icns` is **checked in and generated**, not hand-drawn: `scripts/make-icon.m`
renders it and `scripts/make-icon.sh` packages it with `iconutil`. Both build paths copy the
`.icns` and `Info.plist` names it via `CFBundleIconFile`, so there is no asset catalog.

Two things in the generator exist for a reason:

- The outline is a **superellipse** (`|x|^n + |y|^n = 1`, n = 5) sampled into a path, not
  `-bezierPathWithRoundedRect:`. macOS icon corners are continuously curved; a circular arc looks
  visibly pinched beside real Dock icons.
- Every size is **rendered natively** rather than downsampled from the 1024 master, and the drop
  shadow is omitted at 32pt and below. Downsampling 1024 → 16 turns the artwork to mush, and at
  small sizes the shadow costs more edge contrast than the depth is worth.

The glyph is the same `lock.shield.fill` SF Symbol as the menu bar item, so the two stay in step.
SF Symbols are template images: `[NSColor set]` does not tint them, they have to be recoloured by
compositing source-atop over their own alpha.

### Startup and window lifetime

The settings window is built lazily by `buildWindowIfNeeded`, not at launch — this is most of the
difference between a ~9.6 MB and a ~19 MB idle footprint. `refreshInterface` therefore returns
early when `self.window` is nil, and anything that must update regardless belongs in
`refreshStatusItem`.

The login agent passes `--background`, which `launchedInBackground` checks to suppress the settings
window at sign-in. `main.m` also parses `--self-test` and `--keychain-self-test` before AppKit
starts.

## Conventions

- Identifiers are spelled out in full — `bundleIdentifier`, `processIdentifier`, `application` — never
  `bid`/`pid`/`app`. Match this when adding code.
- Builds are warning-sensitive (`-Wall -Wextra`); unused parameters are marked `__unused`.
- Callbacks capture `__weak typeof(self) weakSelf` and re-check for nil.
- Self-tests must stay side-effect-free on real user state: the Keychain test writes to a
  UUID-suffixed service and deletes it.
