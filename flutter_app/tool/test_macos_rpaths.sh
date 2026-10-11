#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/macos_rpaths.sh"

# Only the unavailable macOS command boundary is substituted here. The real
# parser and cleanup policy run unchanged; native Mach-O editing is additionally
# exercised by test_macos_signing.sh on both macOS architectures.
TEST_RPATHS=(
  "/usr/local/lib/."
  "/usr/local/lib"
  "/usr/local/lib/"
  "/Applications/Xcode_16.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
  "@executable_path/../Frameworks"
  "/usr/lib/swift"
  "/unknown/vendor/lib"
)
otool() {
  [[ "$1" == -l && "$2" == fixture ]] || return 1
  local rpath
  for rpath in "${TEST_RPATHS[@]}"; do
    printf 'Load command 1\n          cmd LC_RPATH\n      cmdsize 48\n         path %s (offset 12)\n' "$rpath"
  done
}
install_name_tool() {
  [[ "$1" == -delete_rpath && "$3" == fixture ]] || return 1
  local rpath
  local remaining=()
  for rpath in "${TEST_RPATHS[@]}"; do
    [[ "$rpath" == "$2" ]] || remaining+=("$rpath")
  done
  TEST_RPATHS=("${remaining[@]}")
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
