#!/bin/sh
# Source candidate only, ad-hoc (-) signature: no private signing key, install,
# launchctl, app launch, Notes event, TCC or real target discovery.
set -eu
notes_host_source=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
notes_host_output=${1:-"$notes_host_source/dist/notes-host-candidate-v1"}
if [ -e "$notes_host_output" ]; then
    echo 'candidate_exists_stop' >&2
    exit 1
fi
mkdir -p "$notes_host_output/ARLNotesBridge.app/Contents/MacOS" "$notes_host_output/ARLNotesBridge.app/Contents/Resources" "$notes_host_output/module-cache"
cp "$notes_host_source/DisabledProfile.json" "$notes_host_output/ARLNotesBridge.app/Contents/Resources/NotesProfile.json"
python3 -B - "$notes_host_source/DisabledProfile.json" "$notes_host_output/NotesBuildSeal.swift" <<'PY'
import hashlib, pathlib, sys
value = hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()
pathlib.Path(sys.argv[2]).write_text('enum NotesBuildSeal { static let profileHash = "' + value + '" }\n')
PY
notes_base="$notes_host_source/../apple_notes"
notes_review="$notes_host_source/../apple_review"
xcrun swiftc -swift-version 6 -module-cache-path "$notes_host_output/module-cache" \
    "$notes_review/Proposal.swift" "$notes_review/PeerAuthentication.swift" "$notes_review/ConsumptionJournal.swift" \
    "$notes_base/NotesProposal.swift" "$notes_base/NotesApprovalEngine.swift" "$notes_base/NotesAutomation.swift" \
    "$notes_host_source/NativeNotesReviewer.swift" "$notes_host_source/NotesWire.swift" "$notes_host_source/NotesHost.swift" \
    "$notes_host_source/NotesClient.swift" "$notes_host_source/NotesSocket.swift" "$notes_host_source/NotesBootstrap.swift" "$notes_host_source/NotesBridgeMain.swift" "$notes_host_output/NotesBuildSeal.swift" \
    -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework Security \
    -o "$notes_host_output/ARLNotesBridge.app/Contents/MacOS/ARLNotesBridge"
cp "$notes_host_source/Info.plist" "$notes_host_output/ARLNotesBridge.app/Contents/Info.plist"
codesign --sign - --identifier local.arl.notesbridge --options runtime \
    --entitlements "$notes_host_source/Entitlements.plist" "$notes_host_output/ARLNotesBridge.app"
codesign --verify --strict "$notes_host_output/ARLNotesBridge.app"
