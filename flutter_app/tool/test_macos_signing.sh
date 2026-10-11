#!/usr/bin/env bash
set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || { echo "Native signing regression requires macOS" >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
clang "$FIXTURE/main.c" -o "$APP/Contents/MacOS/NSOAlbum"

# Exercise a normal versioned framework and FFmpeg's nonmatching executable
# names, plus the symlinks that previously caused duplicate/reordered signing.
for spec in "Standard:Standard" "Avformat:libavformat"; do
  name="${spec%%:*}"
  executable="${spec#*:}"
  framework="$APP/Contents/Frameworks/$name.framework"
  mkdir -p "$framework/Versions/A/Resources"
  clang -dynamiclib "$FIXTURE/library.c" -o "$framework/Versions/A/$executable"
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
