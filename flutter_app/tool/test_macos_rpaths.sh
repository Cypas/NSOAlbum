#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/macos_rpaths.sh"

# Only the unavailable macOS command boundary is substituted here. The real
# parser and cleanup policy run unchanged; native Mach-O editing is additionally
# exercised by test_macos_signing.sh on both macOS architectures.
TEST_RPATHS=(
  "/usr/local/lib/."
  "/usr/local/lib/."
  "/usr/local/lib"
  "/usr/local/lib/"
  "/Applications/Xcode_16.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
  "@executable_path/../Frameworks"
  "/usr/lib/swift"
  "/unknown/vendor/lib"
)
otool() {
  [[ "$2" == fixture ]] || return 1
  if [[ "$1" == -L ]]; then
    printf '%s\n' \
      'fixture (architecture x86_64):' \
      '	@rpath/libfixture.framework/libfixture (compatibility version 1.0.0, current version 1.0.0)' \
      '	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)' \
      'fixture (architecture arm64):' \
      '	@rpath/libfixture.framework/libfixture (compatibility version 1.0.0, current version 1.0.0)' \
      '	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)' \
      '	/unknown/vendor/libfixture.dylib (compatibility version 1.0.0, current version 1.0.0)'
    return 0
  fi
  [[ "$1" == -l ]] || return 1
  local rpath
  for rpath in "${TEST_RPATHS[@]}"; do
    printf 'Load command 1\n          cmd LC_RPATH\n      cmdsize 48\n         path %s (offset 12)\n' "$rpath"
  done
}
install_name_tool() {
  [[ "$1" == -delete_rpath && "$3" == fixture ]] || return 1
  local rpath
  local remaining=()
  local found=false
  for rpath in "${TEST_RPATHS[@]}"; do
    if [[ "$rpath" == "$2" ]]; then found=true; else remaining+=("$rpath"); fi
  done
  [[ "$found" == true ]] || { echo "Runtime path already removed: $2" >&2; return 1; }
  TEST_RPATHS=("${remaining[@]}")
}
# otool's architecture headers must never reach dependency validation, but an
# actual unknown absolute dependency must still be returned (and rejected there).
dependency_output="$(read_dependencies fixture)"
expected_dependencies="$(printf '%s\n' '@rpath/libfixture.framework/libfixture' '/usr/lib/libSystem.B.dylib' '/unknown/vendor/libfixture.dylib')"
[[ "$dependency_output" == "$expected_dependencies" ]] || {
  echo "Universal dependency parser returned headers or lost dependencies" >&2; exit 1;
}
sanitize_build_rpaths fixture
actual="$(read_rpaths fixture)"
expected="$(printf '%s\n' '@executable_path/../Frameworks' '/usr/lib/swift' '/unknown/vendor/lib')"
[[ "$actual" == "$expected" ]] || {
  printf 'Unexpected retained runtime paths:\n%s\n' "$actual" >&2
  exit 1
}
sanitize_build_rpaths fixture
[[ "$(read_rpaths fixture)" == "$expected" ]] || exit 1
echo "Runtime path policy regression passed: host fallback removed, other paths preserved"
