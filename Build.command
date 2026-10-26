#!/bin/bash
set -uo pipefail
cd -- "$(dirname -- "$0")" || exit 1
./build.sh "$@"
result=$?
if [[ -t 0 ]]; then
  printf '\n构建结束（退出码 %s）。按回车关闭窗口。' "$result"
  read -r _
fi
exit "$result"
