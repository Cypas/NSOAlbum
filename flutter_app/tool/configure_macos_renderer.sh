#!/usr/bin/env bash
set -euo pipefail

APP="${1:?App bundle is required}"
ARCH="${2:?Architecture is required}"
PLIST="$APP/Contents/Info.plist"

case "$ARCH" in
  arm64|x64) ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
[[ -f "$PLIST" ]] || { echo "Missing bundle Info.plist" >&2; exit 1; }

if [[ "$ARCH" == "x64" ]]; then
  # Release engines ignore environment switches, and Dart entrypoint arguments
  # are not engine switches. Configure the renderer in the final bundle before
  # signing; the mounted DMG must retain exactly this same configuration.
  /usr/libexec/PlistBuddy -c 'Delete :FLTEnableImpeller' "$PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c 'Add :FLTEnableImpeller bool false' "$PLIST"
  setting="$(/usr/bin/plutil -extract FLTEnableImpeller raw -expect bool -o - "$PLIST")"
  [[ "$setting" == "false" ]] || { echo "Intel Impeller setting was not applied" >&2; exit 1; }
  echo "Intel final bundle: Impeller disabled (Skia renderer)"
fi
