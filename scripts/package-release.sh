#!/bin/zsh
# Packages a built app into a zip suitable for a GitHub release.
#
#     ./scripts/package-release.sh "path/to/Mac App Lock.app" [output dir]
#
# A .app is a DIRECTORY. GitHub's release uploader cannot take a directory, so
# dragging one in uploads the individual files inside it instead of the app.
# It has to be archived first, and the archiver matters: `zip -r` does not
# reliably preserve symlinks, extended attributes, or the code signature, which
# can leave downloaders with a bundle macOS refuses to open. `ditto -c -k
# --keepParent` is what Apple's own notarization workflow uses.
set -euo pipefail

app_path=${1:-}
if [[ -z $app_path || ! -d $app_path ]]; then
    print "usage: $0 <path to .app> [output directory]" >&2
    exit 2
fi
app_path=${app_path:A}
output_dir=${2:-${0:A:h:h}/dist}
mkdir -p "$output_dir"

info_plist="$app_path/Contents/Info.plist"
version=$(plutil -extract CFBundleShortVersionString raw "$info_plist")
archive="$output_dir/MacAppLock-$version.zip"

print "Packaging $app_path"
print "  version: $version"

# Refuse to ship something that will warn or fail on a user's Mac.
if ! codesign --verify --deep --strict "$app_path" 2>/dev/null; then
    print "error: code signature is not valid." >&2
    exit 1
fi
# Capture before matching: piping into `grep -q` under `set -o pipefail` makes
# the pipeline look like it failed, because grep exits on the first match and the
# upstream command dies of SIGPIPE.
# Authority lines only appear at verbosity 2 and above.
signing_info=$(codesign -dv --verbose=2 "$app_path" 2>&1 || true)
if [[ $signing_info != *"Authority=Developer ID Application"* ]]; then
    print "error: not signed with a Developer ID Application identity." >&2
    print "       Export via Xcode: Product > Archive > Distribute App > Developer ID." >&2
    exit 1
fi
if ! xcrun stapler validate "$app_path" >/dev/null 2>&1; then
    print "error: no notarization ticket is stapled to this app." >&2
    print "       Users would see a Gatekeeper warning on first launch." >&2
    exit 1
fi
print "  signature: Developer ID, notarized, stapled"

rm -f "$archive"
ditto -c -k --keepParent "$app_path" "$archive"

# Round trip the archive: a zip that unpacks into something unsigned or
# unstapled is worse than no release at all, and it is invisible until someone
# downloads it.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
ditto -x -k "$archive" "$scratch"
unpacked="$scratch/${app_path:t}"
if [[ ! -d $unpacked ]]; then
    print "error: archive did not unpack to ${app_path:t}" >&2
    exit 1
fi
codesign --verify --deep --strict "$unpacked" \
    || { print "error: signature did not survive archiving." >&2; exit 1; }
xcrun stapler validate "$unpacked" >/dev/null \
    || { print "error: notarization ticket did not survive archiving." >&2; exit 1; }
gatekeeper=$(spctl -a -vv "$unpacked" 2>&1 || true)
if [[ $gatekeeper != *accepted* ]]; then
    print "error: Gatekeeper rejects the unpacked app." >&2
    print "$gatekeeper" >&2
    exit 1
fi
print "  round trip: signature, ticket and Gatekeeper acceptance all survive"

print ""
print "$archive"
print "size: $(du -h "$archive" | cut -f1)"
print "sha256: $(shasum -a 256 "$archive" | cut -d' ' -f1)"
