#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${CONFIGURATION:?Missing Xcode configuration}" in
  Debug|Profile|Release) ;;
  *) echo "Unsupported Flutter configuration: $CONFIGURATION" >&2; exit 1 ;;
esac
TARGET=""
for architecture in ${ARCHS:?Missing Xcode architectures}; do
  case "$architecture" in
    arm64) target=aarch64-apple-darwin ;;
    x86_64) target=x86_64-apple-darwin ;;
    *) echo "Unsupported desktop helper architecture: $architecture" >&2; exit 1 ;;
  esac
  TARGET="${TARGET:+$TARGET,}$target"
done
OUTPUT="${TARGET_BUILD_DIR:?Missing Runner products}/${EXECUTABLE_FOLDER_PATH:?Missing Runner executable folder}/nsoalbum_mtp_worker"
REPORT="${TARGET_BUILD_DIR}/nsoalbum-mtp-worker.build.json"
DART="${FLUTTER_ROOT:?Missing Flutter SDK}/bin/cache/dart-sdk/bin/dart"
"$DART" "$SCRIPT_DIR/build_desktop_native.dart" \
  --target "$TARGET" --configuration "$CONFIGURATION" \
  --output "$OUTPUT" --report "$REPORT" \
  --cargo-log "${TARGET_TEMP_DIR:?Missing Runner temporary directory}/nsoalbum-mtp-worker.cargo.jsonl"
chmod +x "$OUTPUT"
# Xcode's final Runner CodeSign happens after this phase. Ordinary signed
# Debug builds also need their nested helper signed before the root app.
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp=none --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$OUTPUT"
fi
shasum -a 256 "$OUTPUT"
