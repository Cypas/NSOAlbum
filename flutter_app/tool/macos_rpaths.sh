#!/usr/bin/env bash
# Shared by the packaging gate and its native signing regression.
read_rpaths() {
  otool -l "$1" | awk '/cmd LC_RPATH/{in_rpath=1; next} in_rpath && /path /{sub(/^ *path /, ""); sub(/ \(offset.*$/, ""); print; in_rpath=0}'
}

sanitize_build_rpaths() {
  local binary="$1" rpath
  while IFS= read -r rpath; do
    case "$rpath" in
      /Applications/Xcode*.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx|\
      /Volumes/Xcode*.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx|\
      /usr/local/lib|/usr/local/lib/|/usr/local/lib/.)
        # FFmpeg vendor frameworks include this host-only fallback. Removing it
        # is safe only because packaging subsequently resolves every dependency
        # against bundled files or approved system libraries before signing.
        install_name_tool -delete_rpath "$rpath" "$binary" ;;
    esac
  done < <(read_rpaths "$binary")
}
