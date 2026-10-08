# Third-party notices

鱿型相册的 Rust 实现参考了以下项目公开展示的协议流程和相册目录行为。项目没有把这些参考项目作为 Python/C++ 运行时依赖，也没有直接复制其框架耦合代码。

The repository's MIT `LICENSE` covers original source code only. Artwork, personal images, Nintendo marks, fonts, and bundled native dependencies retain separate rights and licenses. See [`ASSET-ATTRIBUTION.md`](ASSET-ATTRIBUTION.md) for the known image assets and the pre-release permission review requirement.

## NSO-Album-Sync

- Project: `Dycool/NSO-Album-Sync`
- License: MIT
- Referenced concepts: Nintendo/Coral media fields, Album directory naming, folder matching, atomic `.part` publishing, capture timestamp preservation and download safety checks.
- The upstream repository's `LICENSE` and `THIRD-PARTY-NOTICES.txt` must be reviewed and included in distributable packages where required.

## splatoon3-nso / s3s iksm.py

- Project: `Cypas/splatoon3-nso`
- Referenced concepts: Nintendo Account PKCE flow, NXAPI OAuth and attestation calls, encrypted Coral request/response flow, NSO headers and Nintendo error retry behavior.
- The referenced file includes GPLv3/upstream attribution. No Python source is shipped as part of the Dart/Rust runtime. Before public distribution, complete a license review of any behavior or material retained from this reference.

## WeAchieve Nintendo Switch Online (Coral) integration write-up

- Reference: public WeAchieve Nintendo Switch Online (Coral) integration write-up; internal research notes are not included in the public repository.
- Referenced concepts: exact per-endpoint headers, encrypted Coral request/response flow, NXAPI `Client-Id` placement, Base64URL response handling and runtime NSO version discovery.
- This reference is used only to document protocol behavior; no external runtime dependency, account credentials, or tokens are distributed.

## flutter_rust_bridge and Cargokit

- `flutter_rust_bridge` 2.13.0 and its generated Cargokit build scaffold are used to bind Flutter/Dart to Rust.
- Their license files remain in the dependency caches/generated scaffold and must be preserved according to their respective licenses in distributed source or notices.

## pinyin

- Package: `pinyin` 3.3.0
- License: BSD-2-Clause
- Used for platform-neutral Traditional/Simplified Chinese normalization in local search. Stored tag names are not rewritten.

## media_kit

- Packages: `media_kit` 1.2.6, `media_kit_video` 2.0.1 and platform video library packages.
- License: MIT for the Dart/Flutter packages and plugin source.
- Used for in-app video playback on Windows, macOS and Android.
- Windows distributions also bundle libmpv and ANGLE runtime libraries downloaded and verified by the package build scripts. Their upstream license notices must remain available in release packages.

## FFmpeg Kit Flutter New — Video

- Package: `ffmpeg_kit_flutter_new_video` 2.5.4.
- License: LGPL-3.0 for the Flutter package and bundled non-GPL FFmpeg video build; the package-generated platform license directory must remain beside distributed executables.
- Used only for local video trimming and multi-video concatenation. The application passes local file paths to the bundled native libraries and does not upload video content.
- Release packaging must preserve the plugin's generated `licenses/ffmpeg_kit_flutter_new_video/` notices and must not replace this dependency with a GPL codec variant without a separate license review.

## Smiley Sans / 得意黑

- Project: `atelier-anchor/smiley-sans`
- Version: 2.0.1
- License: SIL Open Font License 1.1
- Legacy source asset only; it is no longer registered or bundled by the application. Its license text remains at `flutter_app/assets/fonts/SmileySans-OFL.txt`.
