# Third-party notices

NSOAlbum（简体中文界面名“鱿型相册”）的 Rust 实现参考了以下项目公开展示的协议流程和相册目录行为。项目没有把这些参考项目作为 Python/C++ 运行时依赖，也没有直接复制其框架耦合代码。以下引用仅说明协议研究来源，应用当前行为以仓库内 Rust 实现为准。

The repository's MIT `LICENSE` covers original source code only. Artwork, personal images, Nintendo marks, fonts, and bundled native dependencies retain separate rights and licenses. See [`ASSET-ATTRIBUTION.md`](ASSET-ATTRIBUTION.md) for known assets and their documented rights status. Inclusion in a source checkout or published package does not by itself establish a license or grant redistribution rights.

## NSO-Album-Sync

- Project: `Dycool/NSO-Album-Sync`
- License: MIT
- Referenced concepts: Nintendo/Coral media fields, Album directory naming, folder matching, atomic `.part` publishing, capture timestamp preservation and download safety checks.
- The upstream repository's `LICENSE` and `THIRD-PARTY-NOTICES.txt` must be reviewed and included in distributable packages where required.

## [Cypas/splatoon3-nso](https://github.com/Cypas/splatoon3-nso) and upstream s3s

- The repository is licensed under [MIT](https://github.com/Cypas/splatoon3-nso/blob/master/LICENSE). Its protocol and feature behavior was consulted for Nintendo Account PKCE, NXAPI OAuth, encrypted Coral calls, friend data, SplatNet credentials, and related integration behavior.
- The [`iksm.py` reference file](https://github.com/Cypas/splatoon3-nso/blob/master/nonebot_plugin_splatoon3_nso/s3s/iksm.py) separately identifies the [`frozenpandaman/s3s`](https://github.com/frozenpandaman/s3s) source, copyright attribution, and GPLv3 license. The containing repository's MIT license does not replace that file-level notice.
- No Python source or runtime dependency from these projects is included in the Dart/Rust application. Protocol behavior is implemented in Rust. This notice records research sources; it is not a legal determination that any code derived from a reference is covered by the repository MIT license. Review source-level attribution and license obligations before redistributing material that includes copied or adapted code.

## WeAchieve Nintendo Switch Online (Coral) integration write-up

- Reference: public WeAchieve Nintendo Switch Online (Coral) integration write-up; internal research notes are not included in the public repository.
- Referenced concepts: exact per-endpoint headers, encrypted Coral request/response flow, NXAPI `Client-Id` placement, Base64URL response handling and runtime NSO version discovery.
- This reference is used only to document protocol behavior; no external runtime dependency, account credentials, or tokens are distributed.

## flutter_rust_bridge and Cargokit

- `flutter_rust_bridge` 2.13.0 and its generated Cargokit build scaffold are used to bind Flutter/Dart to Rust.
- Their license files remain in the dependency caches/generated scaffold and must be preserved according to their respective licenses in distributed source or notices.

## rustls and rcgen

- Rust packages: `rustls` 0.23 and `rcgen` 0.13, with exact resolved versions in `rust_core/Cargo.lock`.
- `rustls` is available under Apache-2.0 OR ISC OR MIT; `rcgen` is MIT OR Apache-2.0.
- Used for short-lived local device-sync TLS identities and TLS 1.3 connections. Cryptographic primitives and certificate validation remain in the upstream implementations.
- Preserve upstream license obligations, including those of the selected `ring` cryptographic provider and its bundled components, in distributable packages.

## mtp-rs

- Rust package: `mtp-rs` 0.33.0, MIT OR Apache-2.0; exact dependencies are recorded in `rust_core/Cargo.lock`.
- Used by the isolated desktop device-sync helper: Windows uses the system WPD backend; macOS uses the package's USB backend. Android uses the system Storage Access Framework instead.
- Desktop dependencies include `nusb`, the Windows bindings and macOS I/O Kit bindings. Preserve applicable upstream licenses when packaging the helper; this does not add a Python runtime or require a separate file-transfer application.
- The current lockfile resolves `nusb` 0.2.8, `windows` 0.62.2,
  `io-kit-sys` 0.5.0 and `core-foundation` 0.10.1. The helper uses Windows
  WPD or macOS native USB/nusb, not libmtp. No libmtp runtime or replacement
  system driver is bundled.
- Desktop distributions include `nsoalbum_mtp_worker` beside the application
  executable. Operating-system frameworks remain system dependencies.
  Preserve applicable notices for the helper and its bundled dependencies.

## fs2 and tempfile

- Rust packages: `fs2` 0.4.3 and `tempfile` 3.27.0, each MIT OR Apache-2.0.
- `fs2` queries available filesystem space for private device-sync staging and original publication; it is not used for library locking.
- `tempfile` creates owned private temporary files and provides no-clobber publication within the destination directory. The dependency's platform implementations provide the operating-system operations; application code does not add unsafe filesystem calls.
- Sources: `https://github.com/danburkert/fs2-rs` and `https://github.com/Stebalien/tempfile`. Preserve both packages' applicable license obligations in distributed packages.

## winapi-util

- Rust package: `winapi-util` 0.1.11, Unlicense OR MIT, used only on Windows.
- Its safe file-information wrapper checks hard-link counts for the local database and lifecycle-lock carrier. File locking itself uses the Rust standard library; no external service or helper process is required.
- Source: `https://github.com/BurntSushi/winapi-util`. Preserve the applicable upstream license in distributable packages.

## pinyin

- Package: `pinyin` 3.3.0
- License: BSD-2-Clause
- Used for platform-neutral Traditional/Simplified Chinese normalization in local search. Stored tag names are not rewritten.

## media_kit

- Packages: `media_kit` 1.2.6, `media_kit_video` 2.0.1 and platform video library packages.
- License: MIT for the Dart/Flutter packages and plugin source.
- Used for in-app video playback on Windows, macOS and Android.
- Windows distributions also bundle libmpv and ANGLE runtime libraries downloaded and verified by the package build scripts. Their upstream license notices must remain available in release packages.

## flutter_inappwebview

- Package: `flutter_inappwebview` 6.1.5 and its platform implementations.
- License: Apache-2.0; preserve upstream license and notice obligations.
- Uses the operating system's Android WebView, macOS WKWebView, or Windows WebView2 for the official SplatNet 3 site; no Chromium engine is bundled by the application.
- The `Cypas/splatoon3-nso-web` user script was consulted only for the `requestGameWebToken` / `onGameWebTokenReceive` message contract. Its key-input, storage, copying, and remote key-service functionality is not included.

## Current Wi-Fi hints and permission handling

- `network_info_plus` 8.2.2 and `network_info_plus_platform_interface` 3.1.0:
  BSD-3-Clause, with Chromium Authors / Flutter Community notices.
- `permission_handler_android` 13.0.1 and
  `permission_handler_platform_interface` 4.4.1: MIT, Baseflow. These are the
  Android-specific implementation and shared interface pinned in
  `flutter_app/pubspec.lock`; the umbrella `permission_handler` package is not
  a direct dependency. Preserve the applicable upstream notices.
- Used only for on-demand current-network hints and optional foreground
  Android permission requests during pairing. No Wi-Fi scans, BSSID collection,
  background location or network history is added. Declining access does not
  disable the existing secure local connection.
- The Windows SSID bytes returned by the locked plugin are decoded as UTF-8
  before display. The locked macOS plugin's name/IP interface association is
  not assumed; an unknown association is shown rather than mislabelling a
  wired address. No plugin cache or upstream implementation is modified.

## Device pairing QR and camera packages

- Dart/Flutter packages: `mobile_scanner` 7.4.2 (Julian Steenbakker),
  `qr_flutter` 4.1.0 (Luke Freeman), and its `qr` 3.0.2 dependency (Dart QR
  project authors). Each installed package's source is BSD-3-Clause; retain
  its own copyright, conditions and disclaimer in distributed notices.
- Development/test-only packages: `zxing2` 0.2.4 (zxing-dart) and `charcode`
  1.4.0 (Dart project authors), also BSD-3-Clause. `zxing2` verifies rendered
  invitation QR pixels in tests; it is not a product scanning service.
- The QR contains temporary authentication material. The application renders
  it only for the current connection, excludes its contents from accessibility
  speech, and does not save or copy the invitation to the clipboard.
- Package sources and exact license texts:
  `https://pub.dev/packages/mobile_scanner/versions/7.4.2/license`,
  `https://pub.dev/packages/qr_flutter/versions/4.1.0/license`,
  `https://pub.dev/packages/qr/versions/3.0.2/license`,
  `https://pub.dev/packages/zxing2/versions/0.2.4/license`,
  `https://pub.dev/packages/charcode/versions/1.4.0/license`.

### Android ML Kit and CameraX are separate native dependencies

- `mobile_scanner`'s default Android configuration bundles ML Kit barcode
  recognition (`com.google.mlkit:barcode-scanning:17.3.0`) rather than requiring
  a Google Play Services model download for first use. Its Android dependencies
  also include CameraX. The Dart plugin's BSD license does **not** license all
  native SDKs or their bundled components.
- ML Kit is governed by the Google APIs Terms of Service and ML Kit additional
  terms. Scanner input images and recognition results are processed on-device
  and are not sent to Google. The SDK sends diagnostic data, including
  device/application information, per-install identifiers and API
  usage/performance information, and may contact Google for updates. The
  scanner page discloses this before the user enables the camera.
- The resolved CameraX libraries are `camera-core`, `camera-lifecycle`,
  `camera-camera2`, `camera-camera2-pipe` and `featurecombinationquery` 1.6.1.
  Their AndroidX source is Apache-2.0; `camera-core` also includes libyuv
  under BSD-3-Clause. Preserve the licenses and copyright notices for both.
- The bundled scanner also resolves ML Kit common/vision libraries and
  `play-services-mlkit-barcode-scanning` 18.3.1. Google Play services base,
  basement, tasks and ODML image components declare the Android SDK license;
  they are not licensed by the Dart plugin's BSD terms.
- ML Kit AARs include their own `third_party_licenses.json` index and
  `third_party_licenses.txt`, covering bundled components such as Eigen,
  TensorFlow, libyuv, libjpeg-turbo and native runtime libraries. Preserve
  these original texts and each component's terms when distributing Android
  packages. The resolved dependency graph and POM/AAR notices are build inputs,
  not a claim that all transitive packages share one license.
- Official terms and data-disclosure references:
  `https://developers.google.com/ml-kit/terms`,
  `https://developers.google.com/ml-kit/android-data-disclosure`,
  `https://developers.google.com/terms`,
  `https://developers.google.com/ml-kit/vision/barcode-scanning/android`,
  `https://android.googlesource.com/platform/frameworks/support/`.

## FFmpeg Kit Flutter New — Video

- Package: `ffmpeg_kit_flutter_new_video` 2.5.4.
- License: LGPL-3.0 for the Flutter package and bundled non-GPL FFmpeg video build; the package-generated platform license directory must remain beside distributed executables.
- Used only for local video trimming and multi-video concatenation. The application passes local file paths to the bundled native libraries and does not upload video content.
- Release packaging must preserve the plugin's generated `licenses/ffmpeg_kit_flutter_new_video/` notices and must not replace this dependency with a GPL codec variant without a separate license review.

## Smiley Sans / 得意黑（历史字体）

- Project: `atelier-anchor/smiley-sans`
- Version: 2.0.1
- License: SIL Open Font License 1.1
- Historical font, no longer kept as an active source asset or bundled by the application. Its license text remains at `flutter_app/assets/fonts/SmileySans-OFL.txt`.

## Current built-in fonts

The current built-in UI font resources are `DFPT_ZY9.ttf`, `DFP_GBZY9.ttf`, and
`BlitzMain.otf` under `flutter_app/assets/fonts/default/`. Their license or
redistribution status is separate from the MIT source license and must be
confirmed by the maintainer before public binary redistribution.
