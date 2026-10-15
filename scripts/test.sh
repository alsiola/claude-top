#!/bin/sh
# The Command Line Tools ship Swift Testing outside the default search paths.
set -e
cd "$(dirname "$0")/.."
DEV="$(xcode-select -p)/Library/Developer"
exec swift test \
  -Xswiftc -F -Xswiftc "$DEV/Frameworks" \
  -Xlinker -F -Xlinker "$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/usr/lib" \
  "$@"
