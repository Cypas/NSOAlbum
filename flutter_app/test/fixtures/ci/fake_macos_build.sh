#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$1" && pwd -P)"
scenario="$2"
count=0
[[ ! -f "$root/count" ]] || count="$(<"$root/count")"
count=$((count + 1))
printf '%s' "$count" > "$root/count"
if [[ "$scenario" == conflict && "$count" == 1 ]]; then
  bad="$root/cache/https___github_com_sk3llo_ffmpeg_kit_flutter_releases_download_8_1_2_video_ffmpegkit_xcframework_zip"
  mkdir -p "$bad"
  echo "failed downloading binary target: $bad already exists in file system" >&2
  exit 1
fi
if [[ "$scenario" == permanent ]]; then
  echo 'Unrelated signing failure' >&2
  exit 9
fi
if [[ "$scenario" == repeated ]]; then
  bad="$root/cache/https___github_com_sk3llo_ffmpeg_kit_flutter_releases_download_8_1_2_video_ffmpegkit_xcframework_zip"
  mkdir -p "$bad"
  echo "failed downloading binary target: $bad already exists in file system" >&2
  exit 1
fi
if [[ "$scenario" == foreign ]]; then
  echo "binary target: $root/elsewhere already exists in file system" >&2
  exit 1
fi
echo 'Build succeeded'
