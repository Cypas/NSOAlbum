#!/usr/bin/env bash
set -euo pipefail

APP="$(realpath "${1:?Pass the app bundle}")"
ENTITLEMENTS="${2:?Pass the root app entitlements}"
[[ -d "$APP/Contents" && -f "$ENTITLEMENTS" ]] || exit 1

# Signing a bundle's executable path also signs its enclosing container.
# Defer those binaries until the container's nested code has been signed.
BUNDLE_EXECUTABLES=("")
SIGNED_LEAVES=("")
canonical_file() {
  local resolved
  resolved="$(realpath "$1")"
  case "$resolved" in
    "$APP"/*) printf '%s\n' "$resolved" ;;
    *) echo "Signing target escapes the app bundle: $1" >&2; return 1 ;;
  esac
}

while IFS= read -r -d '' bundle; do
  plist=""
  executable_path=""
  if [[ -f "$bundle/Contents/Info.plist" ]]; then
    plist="$bundle/Contents/Info.plist"
    executable_dir="$bundle/Contents/MacOS"
  elif [[ -f "$bundle/Resources/Info.plist" ]]; then
    plist="$bundle/Resources/Info.plist"
    executable_dir="$bundle"
  elif [[ -f "$bundle/Info.plist" ]]; then
    plist="$bundle/Info.plist"
    executable_dir="$bundle"
  fi
  if [[ -n "$plist" ]]; then
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)"
    [[ -n "$executable" ]] || continue
    executable_path="$executable_dir/$executable"
    [[ -f "$executable_path" ]] || { echo "Bundle executable missing: $bundle" >&2; exit 1; }
    BUNDLE_EXECUTABLES+=("$(canonical_file "$executable_path")")
  fi
done < <(find "$APP" -type d \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' -o -name '*.appex' -o -name '*.bundle' \) -print0)

while IFS= read -r -d '' leaf; do
  [[ -f "$leaf" ]] || continue
  resolved="$(canonical_file "$leaf")"
  file -b "$resolved" | grep -q 'Mach-O' || continue
  defer=false
  for executable in "${BUNDLE_EXECUTABLES[@]}" "${SIGNED_LEAVES[@]}"; do
    if [[ "$resolved" == "$executable" ]]; then defer=true; break; fi
  done
  [[ "$defer" == false ]] || continue
  echo "Signing nested Mach-O: ${resolved#"$APP"/}"
  codesign --force --timestamp=none --sign - "$resolved"
  SIGNED_LEAVES+=("$resolved")
done < <(find "$APP/Contents" \( -type f -o -type l \) -print0)

# find -depth gives an explicit inside-out order, including the root .app
# last. Do not use --deep to sign or re-sign a child after its parent.
while IFS= read -r -d '' bundle; do
  echo "Signing bundle: ${bundle#"$APP"/}"
  if [[ "$bundle" == "$APP" ]]; then
    codesign --force --timestamp=none --sign - --entitlements "$ENTITLEMENTS" "$bundle"
  else
    codesign --force --timestamp=none --sign - "$bundle"
  fi
  codesign --verify --strict "$bundle"
done < <(find "$APP" -depth -type d \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' -o -name '*.appex' -o -name '*.bundle' \) -print0)
codesign --verify --deep --strict --verbose=2 "$APP"
