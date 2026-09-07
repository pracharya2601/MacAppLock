#!/bin/zsh
set -euo pipefail

# Build Mac App Lock.
#
#   ./scripts/build-app.sh [output_root]
#
# Environment:
#   SIGN_IDENTITY   codesign identity. Defaults to the first Developer ID
#                   Application identity in the keychain, falling back to an
#                   ad-hoc signature for local development builds.
#   NOTARIZE=1      submit the built app to Apple's notary service and staple the
#                   ticket. Requires NOTARY_PROFILE (see scripts/README below).
#   NOTARY_PROFILE  notarytool keychain profile name. Default: "MacAppLock".

script_dir=${0:A:h}
project_dir=${script_dir:h}
output_root=${1:-"$project_dir/dist"}
app_name="Mac App Lock"
bundle_identifier="com.prakashacharya.MacAppLock"
agent_label="$bundle_identifier.agent"
bundle_path="$output_root/$app_name.app"
build_dir="$project_dir/.build"
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
resources_dir="$project_dir/Resources"
# The executable name matches PRODUCT_NAME in project.yml so this script and the
# Xcode project produce an identical bundle.
executable_name="Mac App Lock"

# ---------------------------------------------------------------- signing identity
if [[ -z ${SIGN_IDENTITY:-} ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application/ {print $2; exit}')
fi
if [[ -z $SIGN_IDENTITY ]]; then
    SIGN_IDENTITY="-"
    print "warning: no Developer ID Application identity found; signing ad-hoc."
    print "warning: an ad-hoc build cannot scope its Keychain item to this app."
fi
# Team identifier, used for the Keychain access group.
team_id=$(print -r -- "$SIGN_IDENTITY" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')

mkdir -p "$build_dir" "$output_root"

# ------------------------------------------------------------------------- compile
# Deprecation warnings are NOT suppressed: the build must stay clean.
xcrun clang \
    -fobjc-arc \
    -fblocks \
    -O2 \
    -Wall \
    -Wextra \
    -mmacosx-version-min=13.0 \
    -isysroot "$sdk_path" \
    -I "$project_dir/Sources" \
    "$project_dir/Sources/main.m" \
    "$project_dir/Sources/AppController.m" \
    "$project_dir/Sources/AuthorizationLedger.m" \
    "$project_dir/Sources/AuthPanelController.m" \
    "$project_dir/Sources/PINVault.m" \
    -framework AppKit \
    -framework Foundation \
    -framework LocalAuthentication \
    -framework Security \
    -framework ServiceManagement \
    -framework UniformTypeIdentifiers \
    -o "$build_dir/MacAppLock"

# Fail fast if the freshly built binary cannot pass its own regression tests.
"$build_dir/MacAppLock" --self-test >/dev/null

# -------------------------------------------------------------------------- bundle
rm -rf "$bundle_path"
mkdir -p "$bundle_path/Contents/MacOS" \
         "$bundle_path/Contents/Resources" \
         "$bundle_path/Contents/Library/LaunchAgents"
cp "$build_dir/MacAppLock" "$bundle_path/Contents/MacOS/$executable_name"
print -n "APPL????" > "$bundle_path/Contents/PkgInfo"

# Info.plist and the login agent plist are checked in under Resources/ and shared
# with the Xcode project, so the two build paths cannot drift apart.
cp "$resources_dir/Info.plist" "$bundle_path/Contents/Info.plist"
# Info.plist is shared with Xcode and uses Xcode build variables. Expand the ones
# this script is responsible for, otherwise the bundle ships a literal
# "$(PRODUCT_BUNDLE_IDENTIFIER)" as its identifier.
plutil -replace CFBundleIdentifier -string "$bundle_identifier" \
    "$bundle_path/Contents/Info.plist"
plutil -replace CFBundleExecutable -string "$executable_name" \
    "$bundle_path/Contents/Info.plist"
cp "$resources_dir/$agent_label.plist" \
   "$bundle_path/Contents/Library/LaunchAgents/$agent_label.plist"
# Referenced by CFBundleIconFile. Regenerate with scripts/make-icon.sh.
cp "$resources_dir/AppIcon.icns" "$bundle_path/Contents/Resources/AppIcon.icns"
plutil -lint "$bundle_path/Contents/Info.plist" >/dev/null
plutil -lint "$bundle_path/Contents/Library/LaunchAgents/$agent_label.plist" >/dev/null

# --------------------------------------------------------------------- entitlements
# keychain-access-groups is a restricted entitlement: without an embedded
# provisioning profile authorising it, AMFI SIGKILLs the process at launch. It is
# therefore only requested when a profile is supplied, via
#   PROVISIONING_PROFILE=/path/to/MacAppLock.provisionprofile
# With a profile the PIN record lives in the data protection Keychain, scoped to
# this team, and other processes are denied outright. Without one, PINVault falls
# back to the file Keychain with an ACL naming this application, so an unauthorised
# read is held for explicit user approval instead of succeeding silently.
entitlements="$build_dir/MacAppLock.entitlements"
cp "$resources_dir/MacAppLock.entitlements" "$entitlements"
profile_path=${PROVISIONING_PROFILE:-}
if [[ -n $profile_path ]]; then
    if [[ ! -f $profile_path ]]; then
        print "error: PROVISIONING_PROFILE not found at $profile_path" >&2
        exit 1
    fi
    if [[ -z $team_id ]]; then
        print "error: a provisioning profile requires a Developer ID identity." >&2
        exit 1
    fi
    cp "$profile_path" "$bundle_path/Contents/embedded.provisionprofile"
    plutil -insert keychain-access-groups -array "$entitlements"
    plutil -insert keychain-access-groups.0 \
        -string "$team_id.$bundle_identifier" "$entitlements"
    print "note: embedding provisioning profile; using the data protection Keychain."
else
    print "note: no PROVISIONING_PROFILE set; PIN uses the ACL protected file Keychain."
fi

# ---------------------------------------------------------------------------- sign
xattr -cr "$bundle_path"
sign_args=(--force --sign "$SIGN_IDENTITY" --identifier "$bundle_identifier" --timestamp)
if [[ $SIGN_IDENTITY != "-" ]]; then
    sign_args+=(--options runtime)
    if [[ -n $profile_path ]]; then
        sign_args+=(--entitlements "$entitlements")
    fi
else
    # Ad-hoc signatures cannot carry a timestamp.
    sign_args=(--force --sign - --identifier "$bundle_identifier")
fi

# Sign inside out: nested code first, then the bundle.
if ! codesign $sign_args "$bundle_path/Contents/MacOS/$executable_name"; then
    xattr -cr "$bundle_path"
    codesign $sign_args "$bundle_path/Contents/MacOS/$executable_name"
fi
if ! codesign $sign_args "$bundle_path"; then
    # File Provider folders may attach Finder metadata between the first cleanup
    # and signing. Clear it once more and retry.
    xattr -cr "$bundle_path"
    codesign $sign_args "$bundle_path"
fi
codesign --verify --deep --strict --verbose=2 "$bundle_path"

# A signed build can still be killed at launch by AMFI over a restricted
# entitlement, which codesign --verify does not catch. Prove it runs.
if ! "$bundle_path/Contents/MacOS/$executable_name" --self-test >/dev/null; then
    print "error: the signed binary failed to launch or self-test." >&2
    print "error: check the entitlements against the embedded provisioning profile." >&2
    exit 1
fi

# ----------------------------------------------------------------------- notarize
if [[ ${NOTARIZE:-0} == 1 ]]; then
    if [[ $SIGN_IDENTITY == "-" ]]; then
        print "error: notarization requires a Developer ID identity." >&2
        exit 1
    fi
    profile=${NOTARY_PROFILE:-MacAppLock}
    archive="$build_dir/$app_name.zip"
    rm -f "$archive"
    ditto -c -k --keepParent "$bundle_path" "$archive"
    xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
    xcrun stapler staple "$bundle_path"
    xcrun stapler validate "$bundle_path"
    rm -f "$archive"
    spctl -a -vvv "$bundle_path"
fi

print "$bundle_path"
