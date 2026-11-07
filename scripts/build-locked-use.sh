#!/usr/bin/env bash
# Build/package only. Never installs a service or modifies authorization policy.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
identity=""; configuration=release; arch_mode=native; bundle_id=com.nia-teams.locked-use.app
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) identity="${2:?Missing identity}"; shift 2 ;;
    --configuration) configuration="${2:?Missing configuration}"; shift 2 ;;
    --arch) arch_mode="${2:?Missing architecture}"; shift 2 ;;
    --bundle-id) bundle_id="${2:?Missing bundle identifier}"; shift 2 ;;
    --help) echo 'Usage: scripts/build-locked-use.sh --identity "Developer ID Application: …" [--configuration debug|release] [--arch native|arm64|x86_64|universal] [--bundle-id com.nia-teams.locked-use.app]'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
done
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS and Xcode are required.' >&2; exit 1; }
[[ -n "$identity" && "$identity" != - && "$bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]] || exit 64
[[ "$configuration" == debug || "$configuration" == release ]] || exit 64
cd "$repo_root"
source scripts/locked-use-build-common.sh
locked_use_architectures
scripts/build-locked-use-components.sh --identity "$identity" --configuration "$configuration" --arch "$arch_mode"
components="$repo_root/.build/locked-use/components"
[[ "$configuration" != release ]] || components="$components-release"
[[ "$arch_mode" == native ]] || components="$components-$arch_mode"
output="$repo_root/dist/$configuration-$arch_mode"
app="$output/LockedUse.app"
rm -rf "$app" "$output/bin/locked-use"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/LockedUse" "$output/bin"
locked_use_build_product locked-use "$app/Contents/MacOS/locked-use"
for component in LockedUseInstaller LockedUseService 'LockedUseGuardian' LockedUseAuth.bundle; do
  ditto "$components/$component" "$app/Contents/Resources/LockedUse/$component"
done
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleExecutable</key><string>locked-use</string>
<key>CFBundleName</key><string>LockedUse</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>$locked_use_version</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSInputMonitoringUsageDescription</key><string>Detect local takeover and relock during Locked Use.</string>
</dict></plist>
PLIST
locked_use_sign --force --options runtime,library --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
# Keep the executable inside its bundle so Bundle.main and code identity agree.
ln -s '../LockedUse.app/Contents/MacOS/locked-use' "$output/bin/locked-use"
printf 'Packaged %s\nCLI: %s\n' "$app" "$output/bin/locked-use"
echo 'Not notarized. No privileged components have been installed.'
