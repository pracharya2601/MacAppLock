# Security policy

Mac App Lock guards access to applications, so a defect in it can expose whatever
it was protecting. Reports are welcome.

## Reporting a vulnerability

Please report privately first, through GitHub's **Report a vulnerability** button
under the repository's Security tab, rather than opening a public issue.

Useful detail: the macOS version, whether the build came from a release or from
source, whether it was signed with a Developer ID and whether Keychain Sharing was
enabled, and the steps to reproduce.

## What is in scope

The interesting parts are the recovery PIN, the authorisation ledger, and the
gap between an application activating and being hidden:

- Reading, recovering, or bypassing the recovery PIN.
- Obtaining access to a protected application without authenticating.
- Making an authorisation outlive what the relock setting allows, for example
  having a relaunched process inherit an earlier unlock.
- Defeating the authentication panel, such as reaching the protected application
  through or around the interaction shield.

## Known limitations, by design

These are documented behaviours rather than vulnerabilities. They are listed so
nobody spends time rediscovering them:

- **This is not an administrator-proof control.** Anyone who can run code as your
  user can quit the app, and Mac App Lock is not a substitute for parental
  controls or device management. Stopping that would require a privileged helper
  installed with administrator approval.
- **A protected app is briefly visible.** Protection reacts to macOS activation
  notifications, measured at a mean of 88 ms and a worst case of 115 ms over five
  cold launches, before the app is hidden.
- **Without a provisioning profile the PIN record is ACL-protected, not
  entitlement-protected.** In that configuration another process reading it
  triggers an explicit approval prompt instead of being refused outright. Builds
  with Keychain Sharing use the data protection Keychain, where such a read is
  denied. `scripts/verify-app.sh` reports which mode a build is in.
- **PIN throttling defends the keyboard, not an offline attack.** Offline
  resistance comes from PBKDF2 at 600,000 rounds and the six digit minimum.
