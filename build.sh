#!/bin/zsh
# Build DualPane.app with the command line tools only (no Xcode project needed).
set -e
cd "$(dirname "$0")"
APP=build/DualPane.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -framework AppKit -framework Quartz \
    Sources/*.swift -o "$APP/Contents/MacOS/DualPane"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force -s - "$APP" 2>/dev/null
echo "built $APP"
if [ "$1" = "install" ]; then
    rm -rf ~/Applications/DualPane.app
    cp -R "$APP" ~/Applications/DualPane.app
    echo "installed ~/Applications/DualPane.app"
fi
