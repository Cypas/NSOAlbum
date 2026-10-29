# Android Build Configuration Regression

This README covers only the adjacent Android test fixtures and opt-in native
regressions. See the [documentation map](../../../../docs/DOCUMENTATION-MAP.md),
[repository layout](../../../../docs/REPOSITORY-LAYOUT.md) and
[complete testing guide](../../../../docs/TESTING.md) for project-wide rules.

This optional integration test evaluates the real Android Gradle project.
It verifies APK ABI filters and Rust targets for Debug, Profile, and Release.
It also verifies that the pinned WebView library uses the optimized default
ProGuard rules accepted by AGP 9 in Debug and Release. The project-scoped
`android/webview_agp_compat.gradle` adapts only that library's obsolete default
rule request; dependency cache sources and application optimizations are unchanged.
It also compiles the Debug Kotlin launcher and links the actual Android
manifest/resources to verify the application ID, launchable activity, localized
application names, and launcher icon. The default name is `NSOAlbum`; Chinese,
including Taiwan and Hong Kong locales, uses `鱿型相册` unchanged.
It also assembles the Release APK and reads its packaged manifest to require
`INTERNET`, `POST_NOTIFICATIONS` and `REQUEST_INSTALL_PACKAGES` for updates, while
requiring the optional all-files access capability while rejecting unrelated
foreground-service permissions. The update policy
JVM harness validates official URLs, package identity, signatures and bounded
copy/hash behavior. It also runs the actual update JobService in an isolated JVM
lifecycle harness, covering stale stops, worker-to-main completion dispatch,
delayed old completions, duplicate completion and cancellation. The small Android
and verification-boundary fixtures are compiled only for this harness and never
included in the application. This is a local test-signing build, not a distribution or device
acceptance test.

Prerequisites:

- A complete JDK 17 or later selected in `JAVA_HOME`, plus an installed Android
  SDK. These tests invoke Gradle directly: Flutter's `jdk-dir` setting does not
  choose Java for that subprocess when the shell still resolves an older JDK.
- Flutter has prepared the Gradle wrapper and Android dependencies. On a fresh
  checkout, prepare them with the Debug Android build command in the project
  testing guide, using the output layout appropriate to that development
  environment.
- No other Android Gradle build is running against the same build directory.

On the project maintainer's workstation, the ignored root `AGENTS.md` adds a
source-copy and fixed-output-root requirement before running these commands.
Public clones do not contain that machine-specific file; contributors should
use their own workspace configuration and the shared rules in `docs/TESTING.md`.

The opt-in suite also executes the production notification permission
coordinator's JUnit regressions with `:app:testDebugUnitTest`, rather than only
compiling them. They cover sync/update prompt sharing, pending-summary delivery,
denial without repeated prompts, mismatched or late callbacks, bounded pending
state, and failed prompt launch. These JVM boundaries do not change a device's
permission settings or replace system-dialog acceptance.

Run from `flutter_app` in the configured build checkout in PowerShell:

```powershell
$env:NSO_VERIFY_ANDROID_BUILD = '1'
flutter test test/android/android_build_configuration_test.dart --reporter expanded
Remove-Item Env:NSO_VERIFY_ANDROID_BUILD
```

The test is explicitly skipped in ordinary Flutter test runs. APK native-library
contents, signatures, and on-device media operations require separate checks.

`test/android/android_media_viewer_device_test.dart` is an opt-in device test.
Run it from the prepared, isolated build checkout:

```powershell
flutter run --debug --target test/android/android_media_viewer_device_test.dart -d <android-device>
```

It uses Flutter's Live widget binding, the authored synthetic video and the real Android media
plugins; it never initializes Rust, secure credentials or a personal library.
It checks that metadata/trim navigation waits for admitted playback and leaves
the source paused, later paging invalidates a waiting editor request, and a
terminal decoder failure does not trap paging or playback of the next item.
Automatic playback enabled and disabled are tested separately, including the
real play button in the latter case. Input waits for the page animation to
reach its target; decoded output and the actual first-frame gate are required.
The trim-editor case also checks that the selection controls expose only one
playback button and that its tooltip follows the real native player's state.
The slow-first-frame case uses an app-owned loopback HTTP server holding back
the authored synthetic H.264 stream. A cached solid-color cover must remain
visibly painted (checked against an independent RGBA pixel) while decoding is
blocked, without a loading spinner. After releasing the response it requires
actual decoded output and first-frame reveal; the native Android progress
slider must retain its State, bounds and opaque track paint across that transition.
Playback controls must stay inside the video region, scrubbing must not page,
and a swipe in the video area must still select the neighboring item. This uses
the production surface directly, without adding test hooks or enabling remote
media URLs in the product. Its optional cover image lives only in the new
synthetic fixture root; inspect it before restoring the normal APK, since
Android may clear code-cache temporary files during replacement.
The five-video case starts on the middle item and requires both adjacent
players to produce decoded output and a first frame before pausing. It checks
volume restoration, the three-item resource window and retirement after paging.
Native error diagnostics use the shared sanitizer before being printed.
Ordinary host suites explicitly skip these device-only cases.
Restore the normal `lib/main.dart` ARM64 Debug package after the device run,
without uninstalling or clearing data. All build output still follows the
repository's configured external build root.

The same entry point has an explicitly enabled large-video case:

```powershell
flutter run --debug --target test/android/android_media_viewer_device_test.dart `
  --dart-define=NSOALBUM_LARGE_VIDEO_QA=true -d <android-device>
```

It uses the bundled FFmpeg encoder to produce real 30-second 720p MPEG-4 video,
requires at least 40 MiB of encoded data, and makes five distinct synthetic
containers through streaming copies and hashes. It does not pad a tiny clip to
claim a large-video test. The case performs 32 forward/backward transitions,
checks the current/neighbor player budget, muted preparation, actual decoded
output and rendered first frame, no extra spinner, and retirement after exit.
`LARGE_VIDEO_QA` markers delimit fixture generation, baseline, warmed playback,
four navigation rounds and release for external process-only memory sampling.
Successful runs remove only their own newly created synthetic temporary root;
failed runs retain it as evidence. This is opt-in and host suites skip it.
Record device/build/codec and sampled PSS separately; one Debug capture cannot
prove a leak or represent H.264/HEVC, another device, or Release performance.
Restore the ordinary package after this entry point as above.

To compare stable post-exit memory over four additional reopen cycles, add
`--dart-define=NSOALBUM_VIDEO_CYCLE_QA=true` to that large-video command. The
same generated videos are reused, each cycle waits for the current and both
neighbors to decode/render, then releases the viewer and waits 12 seconds
before its `cycle-N-released` marker. That exceeds the currently pinned
media_kit native player's five-second deferred final destruction. The test
does not retain retired surface references across these cycles. Capture PSS,
native heap and per-thread `COMM` names at the marked boundaries; Android
toybox's `NAME` column can repeat the process name for every thread and is not
valid evidence of mpv thread counts. Report trends, not a universal no-leak
claim, and restore the ordinary package after the test.

Android UI, updater, branding, APK-contract and build-configuration tests are in
`test/android/` and carry the `platform-android` tag. This classifies the tested
feature, not the execution host: portable tests still run on all hosts.
The build-configuration suite additionally carries `native-android` and keeps
the explicit SDK/JDK opt-in above. CI reports both tags under one Android
category; skipped native tests retain their reason and are not counted as passes.
Run `flutter test --tags platform-android` from `flutter_app` to select Android
tests without suppressing the native suite's declared skip behavior.

`verify_device_sync.gradle` compiles the production SAF mailbox, operation and
picker policies with a pure JVM behavioral harness. It exercises fixed scopes,
bounded byte copies, cancellation, stale picker results and 140 sequential
read/acknowledgement cycles without an ever-growing live directory. From
`flutter_app/android`, run
`.\gradlew.bat -Ptarget-platform=android-arm64 --init-script ../test/fixtures/android/verify_device_sync.gradle verifyDeviceSyncPolicy`.
This does not prove Android document-provider consent, persistence or hardware
I/O. The standalone native probe and its limitations are documented in the
Flutter README. Never run simultaneous native builds in the same checkout.

The same harness also runs `verifyDeviceSyncProviderMetrics`: bounded numeric
timings, cancellation while a provider operation is active, frozen summaries,
clock regression and overflow. This JVM result does not exercise the Android
MethodChannel or real document provider; those require rebuilding and device QA.
