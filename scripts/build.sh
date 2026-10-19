#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
xcrun swift build -c release -debug-info-format none --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
cswitch_bin_dir="$(xcrun swift build -c release --show-bin-path --cache-path .build/cache --config-path .build/config --security-path .build/security)"
cswitch_app="$PWD/dist/Cswitch.app"
mkdir -p "$cswitch_app/Contents/MacOS" "$cswitch_app/Contents/Resources"
xcrun swiftc Sources/Cswitch/AppIcon.swift scripts/GenerateIcons.swift -o .build/generate-icons
.build/generate-icons "$PWD/.build/Icons"
iconutil -c icns .build/Icons/Cswitch.iconset -o "$cswitch_app/Contents/Resources/Cswitch.icns"
cp "$cswitch_bin_dir/Cswitch" "$cswitch_app/Contents/MacOS/Cswitch"
cp -R "$cswitch_bin_dir/Cswitch_Cswitch.bundle" "$cswitch_app/Contents/Resources/"
cp Support/Info.plist "$cswitch_app/Contents/Info.plist"
codesign --force --sign "${CSWITCH_SIGNING_IDENTITY:--}" "$cswitch_app"
# Finder displays the bundle directory's date rather than its executable's date.
touch "$cswitch_app" "$cswitch_app/Contents"
printf '%s\n' "$cswitch_app"
