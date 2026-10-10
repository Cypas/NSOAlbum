#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --architecture arm64|x64 --version VERSION --build-number NUMBER --reports DIRECTORY" >&2
  exit 2
}

ARCH=""
VERSION=""
BUILD_NUMBER=""
REPORTS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --architecture) ARCH="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --build-number) BUILD_NUMBER="${2:-}"; shift 2 ;;
    --reports) REPORTS="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$ARCH" == "arm64" || "$ARCH" == "x64" ]] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || usage
[[ -n "$REPORTS" ]] || usage
[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS packaging requires a Darwin host" >&2; exit 1; }

case "$ARCH" in
  arm64) [[ "$(uname -m)" == "arm64" ]] || { echo "arm64 build requires an arm64 runner" >&2; exit 1; } ;;
  x64) [[ "$(uname -m)" == "x86_64" ]] || { echo "x64 build requires an Intel runner" >&2; exit 1; } ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)"
APP="$PROJECT_ROOT/build/macos/Build/Products/Release/NSOAlbum.app"
DIST="$WORKSPACE_ROOT/dist"
DMG="$DIST/NSOAlbum-macOS-${ARCH}-${VERSION}.dmg"
SMOKE_RUNNER="$SCRIPT_DIR/run_release_smoke.dart"
[[ -f "$SMOKE_RUNNER" ]] || { echo "Missing native smoke driver" >&2; exit 1; }
[[ ! -e "$DMG" ]] || { echo "Refusing to overwrite existing DMG: $DMG" >&2; exit 1; }

cd "$PROJECT_ROOT"
mkdir -p "$DIST" "$REPORTS"
REPORTS="$(cd "$REPORTS" && pwd)"
flutter pub get
flutter config --enable-macos-desktop

if [[ "$ARCH" == "arm64" ]]; then
  EXPECTED="arm64"
  RUST_TARGET="aarch64-apple-darwin"
  flutter config --enable-macos-arm64-only
else
  EXPECTED="x86_64"
  RUST_TARGET="x86_64-apple-darwin"
  flutter config --no-enable-macos-arm64-only
fi

# Flutter forwards only FLUTTER_XCODE_* environment entries to xcodebuild.
export FLUTTER_XCODE_ARCHS="$EXPECTED"
export FLUTTER_XCODE_ONLY_ACTIVE_ARCH=YES
export FLUTTER_XCODE_CODE_SIGNING_ALLOWED=NO
export FLUTTER_XCODE_CODE_SIGNING_REQUIRED=NO
export CARGO_BUILD_TARGET="$RUST_TARGET"

flutter build macos --release --build-name "$VERSION" --build-number "$BUILD_NUMBER"
[[ -d "$APP" ]] || { echo "Missing app bundle: $APP" >&2; exit 1; }

EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
MAIN="$APP/Contents/MacOS/$EXECUTABLE"
[[ -x "$MAIN" ]] || { echo "Missing app executable: $MAIN" >&2; exit 1; }
APP_CANONICAL="$(realpath "$APP")"

FOUND="$(lipo -archs "$MAIN" | tr ' ' '\n' | sort | paste -sd, -)"
[[ "$FOUND" == "$EXPECTED" ]] || { echo "Expected $EXPECTED executable, got $FOUND" >&2; exit 1; }

expand_runtime_path() {
  local value="$1" binary="$2"
  case "$value" in
    @loader_path*) printf '%s%s\n' "$(dirname "$binary")" "${value#@loader_path}" ;;
    @executable_path*) printf '%s%s\n' "$(dirname "$MAIN")" "${value#@executable_path}" ;;
    /*) printf '%s\n' "$value" ;;
    *) return 1 ;;
  esac
}

require_bundle_file() {
  local candidate="$1" resolved
  [[ -f "$candidate" ]] || return 1
  resolved="$(realpath "$candidate")"
  case "$resolved" in
    "$APP_CANONICAL"/*) return 0 ;;
    *) echo "Dependency resolves outside the app bundle: $candidate" >&2; return 1 ;;
  esac
}

read_rpaths() {
  otool -l "$1" | awk '/cmd LC_RPATH/{in_rpath=1; next} in_rpath && /path /{sub(/^ *path /, ""); sub(/ \(offset.*$/, ""); print; in_rpath=0}'
}

is_system_path() {
  case "$1" in
    */../*|*/..) return 1 ;;
    /System/Library/*|/usr/lib/*) return 0 ;;
    *) return 1 ;;
  esac
}

check_rpaths() {
  local binary="$1" rpath expanded resolved parent leaf parent_resolved
  while IFS= read -r rpath; do
    case "$rpath" in
      /System/Library/*|/usr/lib/*)
        is_system_path "$rpath" || { echo "System LC_RPATH contains traversal: $rpath" >&2; return 1; }
        continue ;;
      @loader_path*|@executable_path*)
        expanded="$(expand_runtime_path "$rpath" "$binary")"
        # Ignore a missing optional bundle directory, but never an escaping path.
        if [[ -e "$expanded" ]]; then
          resolved="$(realpath "$expanded")"
        else
          parent="$(dirname "$expanded")"
          leaf="$(basename "$expanded")"
          parent_resolved="$(realpath "$parent" 2>/dev/null || true)"
          [[ -n "$parent_resolved" ]] || {
            echo "LC_RPATH parent cannot be resolved: $rpath" >&2
            return 1
          }
          resolved="$parent_resolved/$leaf"
        fi
        case "$resolved" in
          "$APP_CANONICAL"|"$APP_CANONICAL"/*) ;;
          *) echo "LC_RPATH escapes the app bundle: $rpath" >&2; return 1 ;;
        esac ;;
      *) echo "LC_RPATH relies on a build/cache path: $rpath" >&2; return 1 ;;
    esac
  done < <(read_rpaths "$binary")
}

check_dependencies() {
  local binary="$1" dependency candidate rpath found
  check_rpaths "$binary"
  while IFS= read -r dependency; do
    case "$dependency" in
      /System/Library/*|/usr/lib/*)
        is_system_path "$dependency" || { echo "System dependency contains traversal: $dependency" >&2; return 1; }
        continue ;;
      @loader_path/*|@executable_path/*)
        candidate="$(expand_runtime_path "$dependency" "$binary")"
        require_bundle_file "$candidate" || { echo "Unresolved or external dependency: $dependency in $binary" >&2; return 1; } ;;
      @rpath/*)
        found=false
        while IFS= read -r rpath; do
          candidate="$(expand_runtime_path "$rpath" "$binary")/${dependency#@rpath/}"
          case "$candidate" in
            /System/Library/*|/usr/lib/*)
              is_system_path "$candidate" || return 1
              found=true; break ;;
          esac
          if require_bundle_file "$candidate"; then found=true; break; fi
        done < <(read_rpaths "$binary")
        if [[ "$found" == false ]]; then
          while IFS= read -r rpath; do
            candidate="$(expand_runtime_path "$rpath" "$MAIN")/${dependency#@rpath/}"
            case "$candidate" in
              /System/Library/*|/usr/lib/*)
                is_system_path "$candidate" || return 1
                found=true; break ;;
            esac
            if require_bundle_file "$candidate"; then found=true; break; fi
          done < <(read_rpaths "$MAIN")
        fi
        [[ "$found" == true ]] || { echo "Unresolved rpath: $dependency in $binary" >&2; return 1; } ;;
      *) echo "Non-portable dependency: $dependency in $binary" >&2; return 1 ;;
    esac
  done < <(otool -L "$binary" | tail -n +2 | sed -E 's/^[[:space:]]*//; s/ \(compatibility version.*$//')
}

sanitize_build_rpaths() {
  local binary="$1" rpath
  while IFS= read -r rpath; do
    case "$rpath" in
      /Applications/Xcode*.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx|\
      /Volumes/Xcode*.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx)
        install_name_tool -delete_rpath "$rpath" "$binary" ;;
    esac
  done < <(read_rpaths "$binary")
}

# Inspect and sign Mach-O leaves first, including extensionless framework binaries.
while IFS= read -r -d '' nested; do
  if file -L -b "$nested" | grep -q 'Mach-O'; then
    resolved_nested="$(realpath "$nested")"
    arches="$(lipo -archs "$resolved_nested")"
    [[ " $arches " == *" $EXPECTED "* ]] || { echo "Missing $EXPECTED slice: $nested ($arches)" >&2; exit 1; }
    sanitize_build_rpaths "$resolved_nested"
    check_dependencies "$resolved_nested"
    codesign --force --timestamp=none --sign - "$resolved_nested"
  fi
done < <(find "$APP/Contents" \( -type f -o -type l \) -print0)

# Bundle containers follow their leaves, deepest first. Never use --deep to sign.
while IFS= read -r -d '' bundle; do
  if [[ -d "$bundle/Versions" ]]; then
    while IFS= read -r -d '' version_dir; do
      codesign --force --timestamp=none --sign - "$version_dir"
    done < <(find "$bundle/Versions" -mindepth 1 -maxdepth 1 -type d -print0)
  fi
  codesign --force --timestamp=none --sign - "$bundle"
done < <(find "$APP/Contents" -depth -type d \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' -o -name '*.appex' \) -print0)
codesign --force --timestamp=none --sign - --entitlements "$PROJECT_ROOT/macos/Runner/Release.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
ENTITLEMENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
if [[ "$ENTITLEMENTS" == *"com.apple.security.app-sandbox"* ]]; then
  echo "Packaged app must not contain an app-sandbox entitlement" >&2
  exit 1
fi
dart run "$SMOKE_RUNNER" --launch-app "$APP" --reports-dir "$REPORTS/app"

for fault in rust-initialization video-first-frame trim; do
  fault_reports="$REPORTS/faults/$fault"
  if dart run "$SMOKE_RUNNER" --launch-app "$APP" --reports-dir "$fault_reports" --fault "$fault"; then
    echo "Smoke incorrectly passed injected failure: $fault" >&2
    exit 1
  fi
  native_report="$fault_reports/native-normal.json"
  [[ -s "$native_report" ]] || { echo "Injected failure did not produce a native report: $fault" >&2; exit 1; }
  [[ "$(plutil -extract status raw -o - "$native_report")" == failed ]] || exit 1
  step_index=0
  found=false
  while step_name="$(plutil -extract "steps.$step_index.name" raw -o - "$native_report" 2>/dev/null)"; do
    if [[ "$step_name" == "$fault" ]]; then
      [[ "$(plutil -extract "steps.$step_index.status" raw -o - "$native_report")" == failed ]] || exit 1
      found=true
      break
    fi
    step_index=$((step_index + 1))
  done
  [[ "$found" == true ]] || { echo "Injected failure did not fail the requested native step: $fault" >&2; exit 1; }
done

STAGING="$(mktemp -d "$DIST/.macos-${ARCH}.XXXXXX")"
MOUNT=""
cleanup() {
  if [[ -n "$MOUNT" ]]; then
    hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
    rmdir "$MOUNT" 2>/dev/null || true
  fi
  rm -rf "$STAGING"
}
trap cleanup EXIT
ditto "$APP" "$STAGING/NSOAlbum.app"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$STAGING/licenses"
cp "$WORKSPACE_ROOT/LICENSE" "$STAGING/licenses/MIT-LICENSE.txt"
cp "$WORKSPACE_ROOT/docs/legal/THIRD-PARTY-NOTICES.md" "$STAGING/licenses/"
cp "$WORKSPACE_ROOT/docs/legal/ASSET-ATTRIBUTION.md" "$STAGING/licenses/"
hdiutil create -volname "NSOAlbum" -srcfolder "$STAGING" -format UDZO "$DMG"
hdiutil verify "$DMG"
MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/nsoalbum-dmg.XXXXXX")"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT"
MOUNTED_APP="$MOUNT/NSOAlbum.app"
[[ -d "$MOUNTED_APP" ]] || { echo "DMG did not contain NSOAlbum.app" >&2; exit 1; }
codesign --verify --deep --strict "$MOUNTED_APP"
[[ "$(lipo -archs "$MOUNTED_APP/Contents/MacOS/$EXECUTABLE")" == "$EXPECTED" ]] || exit 1
dart run "$SMOKE_RUNNER" --launch-app "$MOUNTED_APP" --reports-dir "$REPORTS/dmg"
hdiutil detach "$MOUNT" -quiet
rmdir "$MOUNT"
MOUNT=""
trap - EXIT
rm -rf "$STAGING"
echo "Created $DMG"
