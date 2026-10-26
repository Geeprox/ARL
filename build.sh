#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd -P)"
if [[ ! -x /usr/bin/python3 ]]; then
  echo '构建失败：缺少 macOS Python 3；请先配置 Xcode Command Line Tools。' >&2
  exit 1
fi
exec /usr/bin/python3 -B "$ROOT/script/build_release.py" "$@"
