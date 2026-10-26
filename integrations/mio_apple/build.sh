#!/bin/sh
set -eu
mio_source=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
review_source="$mio_source/../apple_review"
mkdir -p "$mio_source/dist/ARLMioAppleBridge.app/Contents/MacOS" "$mio_source/dist/module-cache"
xcrun swiftc -swift-version 6 -module-cache-path "$mio_source/dist/module-cache" "$mio_source/main.swift" "$mio_source/Consumer.swift" "$mio_source/Transport.swift" "$mio_source/Host.swift" "$mio_source/OwnedProcesses.swift" "$mio_source/StartupDiagnostics.swift" "$mio_source/Setup.swift" "$review_source/Proposal.swift" "$review_source/PeerAuthentication.swift" "$review_source/ConsumptionJournal.swift" "$review_source/ApprovalEngine.swift" "$review_source/EventKitEffects.swift" -framework EventKit -framework AppKit -framework CoreGraphics -framework Security -o "$mio_source/dist/ARLMioAppleBridge.app/Contents/MacOS/ARLMioAppleBridge"
cp "$mio_source/Info.plist" "$mio_source/dist/ARLMioAppleBridge.app/Contents/Info.plist"
codesign --force --sign - --identifier local.arl.mioapplebridge "$mio_source/dist/ARLMioAppleBridge.app"
codesign --verify --strict "$mio_source/dist/ARLMioAppleBridge.app"
