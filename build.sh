#!/bin/zsh
set -eu
cd "${0:A:h}"
./test.sh
mkdir -p UsageBar.app/Contents/MacOS
swiftc -O -target arm64-apple-macosx13.0 -swift-version 5 Sources/UsageModel.swift Sources/main.swift -o UsageBar.app/Contents/MacOS/UsageBar -framework AppKit -framework SwiftUI -framework UserNotifications -framework ServiceManagement
cat > UsageBar.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>UsageBar</string>
<key>CFBundleIdentifier</key><string>se.anderssjoberg.usagebar</string>
<key>CFBundleName</key><string>UsageBar</string>
<key>CFBundleDisplayName</key><string>UsageBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - UsageBar.app
