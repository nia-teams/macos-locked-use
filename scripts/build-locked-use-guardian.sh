#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
identity="-"
configuration="debug"
arch_mode="native"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) identity="${2:?Missing signing identity}"; shift 2 ;;
    --configuration) configuration="${2:?Missing configuration}"; shift 2 ;;
    --arch) arch_mode="${2:?Missing architecture}"; shift 2 ;;
    *) echo 'Usage: scripts/build-locked-use-guardian.sh [--identity ID] [--configuration debug|release] [--arch native|arm64|x86_64|universal]' >&2; exit 64 ;;
  esac
done
[[ "$configuration" == debug || "$configuration" == release ]] || exit 64
cd "$repo_root"
source "$repo_root/scripts/locked-use-build-common.sh"
locked_use_architectures
output="$repo_root/.build/locked-use"
if [[ "$configuration" == release ]]; then output="$output/release"; fi
if [[ "$arch_mode" != native ]]; then output="$output-$arch_mode"; fi
mkdir -p "$output"
helper="$output/LockedUseGuardian"
locked_use_build_product LockedUseGuardian "$helper"
if [[ "$identity" == "-" ]]; then
  locked_use_sign --force --identifier com.nia-teams.locked-use.guardian --sign - "$helper"
else
  locked_use_sign --force --options runtime,library --timestamp --identifier com.nia-teams.locked-use.guardian --sign "$identity" "$helper"
fi
codesign --verify --strict "$helper"
printf '%s\n' "$helper"
