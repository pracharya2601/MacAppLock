#!/bin/zsh
# Post-signing verification for a built Mac App Lock bundle.
#
#     ./scripts/verify-app.sh "dist/Mac App Lock.app"
#
# This has to run AFTER code signing, which is why it is not a build phase:
# Xcode signs once every build phase has finished, so a script phase only ever
# sees an unsigned binary, and an unsigned arm64 binary is SIGKILLed on launch.
set -euo pipefail

app_path=${1:-}
if [[ -z $app_path || ! -d $app_path ]]; then
    print "usage: $0 <path to Mac App Lock.app>" >&2
    exit 2
fi

executable="$app_path/Contents/MacOS/Mac App Lock"
agent_plist="$app_path/Contents/Library/LaunchAgents/com.prakashacharya.MacAppLock.agent.plist"
failures=0

check() {
    if eval "$2" >/dev/null 2>&1; then
        print "  pass  $1"
    else
        print "  FAIL  $1"
        ((failures++)) || true
    fi
}

print "Verifying $app_path"

check "executable present"        "[[ -x \"$executable\" ]]"
check "login agent plist present" "[[ -f \"$agent_plist\" ]]"
check "login agent plist valid"   "plutil -lint \"$agent_plist\""
check "Info.plist valid"          "plutil -lint \"$app_path/Contents/Info.plist\""
check "app icon present"          "[[ -f \"$app_path/Contents/Resources/AppIcon.icns\" ]]"
check "app icon referenced"       "[[ \$(plutil -extract CFBundleIconFile raw \"$app_path/Contents/Info.plist\") == AppIcon ]]"
check "marked as agent (LSUIElement)" \
    "[[ \$(plutil -extract LSUIElement raw \"$app_path/Contents/Info.plist\") == true ]]"
check "code signature valid"      "codesign --verify --deep --strict \"$app_path\""

# The signature must actually be usable, not merely present. An entitlement the
# embedded provisioning profile does not authorise makes AMFI SIGKILL the process
# at launch, which codesign --verify does not detect.
check "signed binary launches and passes self-test" "\"$executable\" --self-test"
check "Keychain round trip"                         "\"$executable\" --keychain-self-test"

print ""
print "Signature:"
codesign -d --verbose=2 "$app_path" 2>&1 | grep -E "^(Authority|TeamIdentifier|CodeDirectory)" | sed 's/^/  /'
# Capture first, then match. Piping into `grep -q` under `set -o pipefail` makes
# the pipeline report failure: grep exits on the first match and the upstream
# command dies of SIGPIPE (141), which reads as "not found".
signed_entitlements=$(codesign -d --entitlements - --xml "$app_path" 2>/dev/null || true)
if [[ $signed_entitlements == *keychain-access-groups* ]]; then
    print "  Keychain: data protection Keychain (entitlement present)"
    print "  Unauthorised reads of the PIN record are refused outright."
else
    print "  Keychain: file Keychain with per-app ACL (no entitlement)"
    print "  Unauthorised reads of the PIN record require explicit user approval."
fi
print ""
print "Gatekeeper:"
spctl -a -vvv "$app_path" 2>&1 | sed 's/^/  /' || true

print ""
if (( failures > 0 )); then
    print "$failures check(s) failed."
    exit 1
fi
print "All checks passed."
