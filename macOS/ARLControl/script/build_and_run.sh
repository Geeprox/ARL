#!/bin/bash
# Future copy is build-only: the frozen production entrypoint is unchanged.
set -euo pipefail
cd "$(dirname "$0")/../../.."
case "${1:---build-only}" in
 --build-only|--dev-build-only) /opt/homebrew/bin/python3.13 script/build_future_control.py ;;
 *) echo 'Oct3 source candidate is held and build-only. No signing or app launch is available here.' >&2; exit 2 ;;
esac
