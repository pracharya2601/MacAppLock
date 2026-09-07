#!/bin/zsh
# Regenerates Resources/AppIcon.icns from scripts/make-icon.m.
#
# The icon is checked in, so this only needs running when the artwork changes.
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
build_dir="$project_dir/.build"
iconset="$build_dir/AppIcon.iconset"
output="$project_dir/Resources/AppIcon.icns"

mkdir -p "$build_dir"
xcrun clang -fobjc-arc -O2 -Wall -Wextra \
    -framework AppKit -framework Foundation \
    "$script_dir/make-icon.m" -o "$build_dir/make-icon"

rm -rf "$iconset"
"$build_dir/make-icon" "$iconset"
# iconutil rejects anything that is not a recognised icon_*.png name.
rm -f "$iconset/preview-1024.png"
iconutil --convert icns --output "$output" "$iconset"
print "$output"
