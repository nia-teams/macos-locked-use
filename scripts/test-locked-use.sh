#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'Full build/tests require macOS and Xcode.' >&2; exit 1; }
for configuration in debug release; do
  swift build -c "$configuration"
  swift test -c "$configuration"
done
