#!/usr/bin/env bash
set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || { echo "Native signing regression requires macOS" >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/test_macos_rpaths.sh"
source "$SCRIPT_DIR/macos_rpaths.sh"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/nsoalbum-signing.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
APP="$FIXTURE/NSOAlbum.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"

cat > "$FIXTURE/main.c" <<'EOF'
int main(void) { return 0; }
EOF
cat > "$FIXTURE/library.c" <<'EOF'
int fixture_value(void) { return 42; }
EOF
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.nsoalbum.signing</string>
<key>CFBundleExecutable</key><string>NSOAlbum</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF
clang "$FIXTURE/main.c" -Wl,-rpath,/usr/local/lib/. -Wl,-rpath,@executable_path/../Frameworks -o "$APP/Contents/MacOS/NSOAlbum"
native_rpaths="$(read_rpaths "$APP/Contents/MacOS/NSOAlbum")"
[[ "$native_rpaths" == *"/usr/local/lib/."* ]] || {
  echo "Native fixture did not reproduce the vendor host rpath" >&2; exit 1;
}
sanitize_build_rpaths "$APP/Contents/MacOS/NSOAlbum"
[[ "$(read_rpaths "$APP/Contents/MacOS/NSOAlbum")" == '@executable_path/../Frameworks' ]] || {
  echo "Native runtime path cleanup did not preserve the bundled search path" >&2; exit 1;
}

# Exercise a normal versioned framework and FFmpeg's nonmatching executable
# names, plus the symlinks that previously caused duplicate/reordered signing.
for spec in "Standard:Standard" "Avformat:libavformat"; do
  name="${spec%%:*}"
  executable="${spec#*:}"
  framework="$APP/Contents/Frameworks/$name.framework"
  mkdir -p "$framework/Versions/A/Resources"
  if [[ "$name" == Standard ]]; then
    # Vendor frameworks can be universal even though the root app is native.
    # Reproduce per-slice otool headers and duplicate LC_RPATH records.
    clang -dynamiclib -arch arm64 -arch x86_64 "$FIXTURE/library.c" \
      -Wl,-install_name,@rpath/Standard.framework/Standard \
      -Wl,-rpath,/usr/local/lib/. \
      -Wl,-rpath,@loader_path/../../../ \
      -o "$framework/Versions/A/$executable"
    fixture_dependencies="$(read_dependencies "$framework/Versions/A/$executable")"
    [[ "$fixture_dependencies" != *"(architecture "* ]] || {
      echo "Universal native dependency parser returned a slice header" >&2; exit 1;
    }
    [[ "$fixture_dependencies" == *'@rpath/Standard.framework/Standard'* &&
       "$fixture_dependencies" == *'/usr/lib/libSystem.B.dylib'* ]] || {
      echo "Universal native dependency parser lost real dependencies" >&2; exit 1;
    }
    sanitize_build_rpaths "$framework/Versions/A/$executable"
    [[ "$(read_rpaths "$framework/Versions/A/$executable")" == '@loader_path/../../../' ]] || {
      echo "Universal native runtime path cleanup failed" >&2; exit 1;
    }
  else
    clang -dynamiclib "$FIXTURE/library.c" -o "$framework/Versions/A/$executable"
  fi
  # arm64 clang implicitly signs Mach-O output. Explicitly remove that
  # signature so both architectures really exercise unsigned nested code.
  codesign --remove-signature "$framework/Versions/A/$executable" 2>/dev/null || true
  if codesign --verify "$framework/Versions/A/$executable" 2>/dev/null; then
    echo "Unsigned fixture binary still has a valid signature" >&2
    exit 1
  fi
  cat > "$framework/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.nsoalbum.$name</string>
<key>CFBundleExecutable</key><string>$executable</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
EOF
  ln -s A "$framework/Versions/Current"
  ln -s "Versions/Current/$executable" "$framework/$executable"
  ln -s Versions/Current/Resources "$framework/Resources"
done
# Reproduce the original failure: signing the outer executable before its
# nested frameworks must not be accepted.
if codesign --force --sign - "$APP" 2>"$FIXTURE/early-sign.log"; then
  echo "Fixture did not reproduce unsigned nested-code rejection" >&2
  exit 1
fi
bash "$SCRIPT_DIR/sign_macos_app.sh" "$APP" "$SCRIPT_DIR/../macos/Runner/Release.entitlements"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/NSOAlbum"
printf 'tampered resource\n' > "$APP/Contents/Frameworks/Avformat.framework/Versions/A/Resources/tampered.txt"
if codesign --verify --deep --strict "$APP" 2>"$FIXTURE/tampered.log"; then
  echo "Tampered nested framework incorrectly passed verification" >&2
  exit 1
fi
echo "Native signing regression passed: nested frameworks, launch and tamper rejection"
