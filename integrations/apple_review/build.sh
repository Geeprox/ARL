#!/bin/sh
# Source library only: no installation, listener, launch, TCC or runtime grant.
set -eu
review_source=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$review_source/dist/module-cache"
xcrun swiftc -swift-version 6 -module-cache-path "$review_source/dist/module-cache" -emit-library -emit-module -module-name ARLAppleReview "$review_source/Proposal.swift" "$review_source/PeerAuthentication.swift" "$review_source/ConsumptionJournal.swift" "$review_source/ApprovalEngine.swift" "$review_source/EventKitEffects.swift" -framework EventKit -framework AppKit -framework CoreGraphics -framework Security -o "$review_source/dist/libARLAppleReview.dylib" -emit-module-path "$review_source/dist/ARLAppleReview.swiftmodule"
