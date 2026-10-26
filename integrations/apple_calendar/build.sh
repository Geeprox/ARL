#!/bin/sh
# Build only. Never launches apps, kills processes, requests access or installs.
set -eu
calendar_source=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
calendar_dist="$calendar_source/dist"
mkdir -p "$calendar_dist/build" "$calendar_dist/module-cache" "$calendar_dist/ARLCalendarBridge.app/Contents/MacOS"
cp "$calendar_source/CalendarWriteHelper.swift" "$calendar_dist/build/main.swift"
xcrun swiftc -swift-version 6 -module-cache-path "$calendar_dist/module-cache" "$calendar_dist/build/main.swift" "$calendar_source/ReviewClient.swift" "$calendar_source/NativeEffectBoundary.swift" "$calendar_source/CalendarSeal.swift" "$calendar_source/../../examples/ARLClient.swift" -framework EventKit -framework AppKit -o "$calendar_dist/ARLCalendarBridge.app/Contents/MacOS/ARLCalendarBridge"
cp "$calendar_source/Info.plist" "$calendar_dist/ARLCalendarBridge.app/Contents/Info.plist"
