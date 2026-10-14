# Android Build Configuration Regression

This optional integration test evaluates the real Android Gradle project.
It verifies APK ABI filters and Rust targets for Debug, Profile, and Release.
It also compiles the Debug Kotlin launcher and links the actual Android
manifest/resources to verify the application ID, launchable activity, localized
application names, and launcher icon. The default name is `NSOAlbum`; Chinese,
including Taiwan and Hong Kong locales, uses `鱿型相册` unchanged.
It also assembles the Release APK and reads its packaged manifest to require
`INTERNET`, `POST_NOTIFICATIONS` and `REQUEST_INSTALL_PACKAGES` for updates, while
rejecting all-files storage and foreground-service permissions. The update policy
JVM harness validates official URLs, package identity, signatures and bounded
copy/hash behavior. It also runs the actual update JobService in an isolated JVM
lifecycle harness, covering stale stops, worker-to-main completion dispatch,
delayed old completions, duplicate completion and cancellation. The small Android
and verification-boundary fixtures are compiled only for this harness and never
included in the application. This is a local test-signing build, not a distribution or device
acceptance test.

Prerequisites:

- A complete JDK selected in `JAVA_HOME`, plus an installed Android SDK.
- Flutter has prepared the local Gradle wrapper and Android dependencies.
  On a fresh checkout, first run
  `flutter build apk --debug --target-platform android-arm64`.
- No other Android Gradle build is running against this checkout.

Run from `flutter_app` in PowerShell:

```powershell
$env:NSO_VERIFY_ANDROID_BUILD = '1'
flutter test test/android_build_configuration_test.dart --reporter expanded
Remove-Item Env:NSO_VERIFY_ANDROID_BUILD
```

The test is explicitly skipped in ordinary Flutter test runs. APK native-library
contents, signatures, and on-device media operations require separate checks.

`test/android_branding_test.dart` runs without the Android toolchain and compares
all five density-specific launcher PNGs with the shared desktop artwork.
The linked-resource test also verifies that Android resolves the launcher to
these five PNGs with transparent corners, without an adaptive background layer.
Regenerate the checked-in transparent PNG assets on Windows with
`.\tool\generate_android_icons.ps1` after changing `assets/tray/app_icon.png`.
