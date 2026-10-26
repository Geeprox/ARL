#!/bin/sh
# Build only; no app launch, kill, install, EventKit access or TCC request.
set -eu
reminders_source=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
reminders_dist="$reminders_source/dist"
mkdir -p "$reminders_dist/build" "$reminders_dist/module-cache" "$reminders_dist/ARLRemindersBridge.app/Contents/MacOS"
cp "$reminders_source/RemindersWriteHelper.swift" "$reminders_dist/build/main.swift"
xcrun swiftc -swift-version 6 -module-cache-path "$reminders_dist/module-cache" "$reminders_dist/build/main.swift" "$reminders_source/ConfirmationWindow.swift" "$reminders_source/ReminderStore.swift" "$reminders_source/ReviewClient.swift" "$reminders_source/NativeEffectBoundary.swift" "$reminders_source/RemindersSeal.swift" "$reminders_source/../../examples/ARLClient.swift" -framework EventKit -framework AppKit -framework CoreGraphics -o "$reminders_dist/ARLRemindersBridge.app/Contents/MacOS/ARLRemindersBridge"
cp "$reminders_source/Info.plist" "$reminders_dist/ARLRemindersBridge.app/Contents/Info.plist"
