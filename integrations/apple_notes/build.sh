#!/bin/sh
# Compile only. Never execute Apple events, launch Notes, sign/install an app,
# request TCC, or modify any reviewed/frozen package.
set -eu
notes_source=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
notes_output=${1:-"$notes_source/dist"}
mkdir -p "$notes_output/module-cache"
review_source="$notes_source/../apple_review"
xcrun swiftc -swift-version 6 -module-cache-path "$notes_output/module-cache" \
  -emit-library -emit-module -module-name ARLNotesCreate \
  "$review_source/Proposal.swift" "$review_source/PeerAuthentication.swift" "$review_source/ConsumptionJournal.swift" \
  "$notes_source/NotesProposal.swift" "$notes_source/NotesApprovalEngine.swift" "$notes_source/NotesAutomation.swift" \
  -framework ApplicationServices -framework CoreGraphics -framework Security \
  -o "$notes_output/libARLNotesCreate.dylib" -emit-module-path "$notes_output/ARLNotesCreate.swiftmodule"
