#!/usr/bin/env bash
# OS/toolchain doubles for the real packaging scripts; never a native Mac test.
set -euo pipefail
tool="$(basename "$0")"
printf '%s %s\n' "$tool" "$*" >> "$NSO_FAKE_LOG"
case "$tool" in
  uname)
    [[ "$1" == -s ]] && echo Darwin || echo "${NSO_FAKE_ARCH:-arm64}"
    ;;
  flutter)
    if [[ "${1:-}" == build ]]; then
      CONFIGURATION=Release ARCHS="${NSO_FAKE_ARCH:-arm64}" \
      TARGET_BUILD_DIR="$(dirname "$NSO_FAKE_APP")" \
      EXECUTABLE_FOLDER_PATH=NSOAlbum.app/Contents/MacOS \
      TARGET_TEMP_DIR="$NSO_FAKE_STATE" CODE_SIGNING_ALLOWED=NO \
      bash "$NSO_FAKE_PROJECT/tool/build_macos_mtp_worker.sh"
    fi
    ;;
  dart)
    [[ "${1:-}" != run ]] || shift
    script="${1:-}"; shift
    output="" record="" bundle="" write="" fault="" reports=""
    all="$*"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output) output="$2" ;;
        --report|--build-record) record="$2" ;;
        --bundle) bundle="$2" ;;
        --write-record) write="$2" ;;
        --fault) fault="$2" ;;
        --reports-dir) reports="$2" ;;
      esac
      shift
      [[ $# -eq 0 ]] || shift
    done
    case "$script" in
      *build_desktop_native.dart)
        [[ "$NSO_FAKE_FAIL" != build ]] || exit 31
        mkdir -p "$(dirname "$output")"
        cp "$NSO_FAKE_SEED" "$output"
        chmod +x "$output"
        sha256sum "$output" | cut -d ' ' -f 1 > "$record"
        ;;
      *verify_mtp_worker.dart)
        worker="$bundle/Contents/MacOS/nsoalbum_mtp_worker"
        [[ -s "$worker" && -x "$worker" && ! -L "$worker" && -s "$record" ]] || exit 32
        actual="$(sha256sum "$worker" | cut -d ' ' -f 1)"
        if [[ -n "$write" ]]; then
          [[ "$NSO_FAKE_FAIL" != final-record ]] || exit 33
          printf '%s\n' "$actual" > "$write"
        else
          [[ "$actual" == "$(tr -d '\r\n' < "$record")" ]] || exit 34
        fi
        ;;
      *run_release_smoke.dart)
        mkdir -p "$reports"
        if [[ -n "$fault" ]]; then
          printf '{"status":"failed","steps":[{"name":"%s","status":"failed"}]}\n' "$fault" > "$reports/native-normal.json"
          exit 35
        fi
        ;;
      *) echo "Unexpected fake Dart command: $script $all" >&2; exit 36 ;;
    esac
    ;;
  PlistBuddy)
    case "$2" in
      'Print :CFBundleExecutable') echo NSOAlbum ;;
      'Print :CFBundleShortVersionString') echo 0.2.14 ;;
      'Print :CFBundleVersion') echo 47 ;;
      'Delete :FLTEnableImpeller'|'Add :FLTEnableImpeller bool false') ;;
      *) exit 37 ;;
    esac
    ;;
  file)
    path="${!#}"
    case "$path" in
      */nsoalbum_mtp_worker|*/NSOAlbum|*.dylib) echo 'Mach-O 64-bit executable' ;;
      *) echo data ;;
    esac
    ;;
  lipo)
    if [[ "${!#}" == */nsoalbum_mtp_worker && "$NSO_FAKE_FAIL" == wrong-arch ]]; then
      echo x86_64
    else
      echo "${NSO_FAKE_ARCH:-arm64}"
    fi
    ;;
  otool)
    path="${!#}"
    if [[ "$1" == -L ]]; then
      printf '%s:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n' "$path"
    elif [[ ! -e "$NSO_FAKE_STATE/$(basename "$path").sanitized" ]]; then
      printf ' cmd LC_RPATH\n path /usr/local/lib (offset 12)\n'
    fi
    ;;
  install_name_tool)
    touch "$NSO_FAKE_STATE/$(basename "${!#}").sanitized"
    ;;
  codesign)
    if [[ "$1" == --force && "${!#}" == */nsoalbum_mtp_worker ]]; then
      [[ "$NSO_FAKE_FAIL" != sign-helper ]] || exit 38
      printf 'signed\n' >> "${!#}"
    fi
    ;;
  plutil)
    case "$2" in
      FLTEnableImpeller) echo false ;;
      status|steps.0.status) echo failed ;;
      steps.0.name) basename "$(dirname "${!#}")" ;;
      *) exit 39 ;;
    esac
    ;;
  ditto) cp -R "$1" "$2" ;;
  shasum)
    [[ "$1" == -a && "$2" == 256 ]] || exit 42
    sha256sum "$3"
    ;;
  ln)
    [[ "$1" == -s && "$2" == /Applications ]] || exit 43
    # The Windows host has no /Applications. Only this OS shortcut boundary
    # is doubled; the actual staging/copy/sign/verify flow remains in place.
    mkdir "$3"
    ;;
  hdiutil)
    case "$1" in
      create) touch "${!#}" ;;
      verify) ;;
      attach)
        mount="${!#}"
        cp -R "$NSO_FAKE_APP" "$mount/NSOAlbum.app"
        ;;
      detach)
        mount="${!#}"
        if [[ "$NSO_FAKE_FAIL" == detach-once &&
              ! -e "$NSO_FAKE_STATE/detach-retried" &&
              "$*" != *-force* ]]; then
          touch "$NSO_FAKE_STATE/detach-retried"
          echo "hdiutil: detach: Resource busy" >&2
          exit 16
        fi
        case "$mount" in
          "$NSO_FAKE_ROOT"/*) rm -rf -- "$mount/NSOAlbum.app" ;;
          *) exit 40 ;;
        esac
        ;;
    esac
    ;;
  *) echo "Unexpected fake macOS tool: $tool" >&2; exit 41 ;;
esac
