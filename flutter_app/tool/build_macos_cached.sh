#!/usr/bin/env bash
set -euo pipefail

# Only a recognized SwiftPM artifact collision earns one retry. Compiler,
# signing and media failures must keep their original exit status.
CACHE="${1:?SwiftPM artifact cache is required}"
shift
[[ $# -gt 0 ]] || { echo "Build command is required" >&2; exit 2; }
[[ ! -L "$CACHE" ]] || { echo "Refusing a linked artifact cache" >&2; exit 1; }
mkdir -p "$CACHE"
CACHE="$(cd "$CACHE" && pwd -P)"
LOG_DIR="$(mktemp -d)"
trap 'rm -f "$LOG_DIR/build.log"; rmdir "$LOG_DIR"' EXIT

run_build() {
  set +e
  "$@" 2>&1 | tee "$LOG_DIR/build.log"
  result="${PIPESTATUS[0]}"
  set -e
}
run_build "$@"
[[ "$result" -ne 0 ]] || exit 0
retry=false
while IFS= read -r line; do
  [[ "$line" == *" already exists in file system"* ]] || continue
  candidate="${line%% already exists in file system*}"
  candidate="${candidate##*: }"
  name="$(basename "$candidate")"
  [[ "$name" =~ ^https___github_com_sk3llo_ffmpeg_kit_flutter_releases_download_[A-Za-z0-9_]+_xcframework_zip$ ]] || continue
  [[ -d "$candidate" && ! -L "$candidate" ]] || continue
  parent="$(cd "$(dirname "$candidate")" && pwd -P)"
  [[ "$parent" == "$CACHE" ]] || continue
  echo "Removing only the conflicting SwiftPM artifact: $name"
  rm -rf -- "$CACHE/$name"
  retry=true
done < "$LOG_DIR/build.log"
[[ "$retry" == true ]] || exit "$result"
echo "Retrying dependency resolution once after targeted artifact cleanup"
run_build "$@"
exit "$result"
