# Android Build Configuration Regression

This optional integration test evaluates the real Android Gradle project.
It verifies APK ABI filters and Rust targets for Debug, Profile, and Release.
It also compiles the Debug Kotlin launcher and links the actual Android
manifest/resources to verify the application ID, launchable activity, localized
application names, and launcher icon. The default name is `NSOAlbum`; Chinese,
including Taiwan and Hong Kong locales, uses `鱿型相册` unchanged.
It does not assemble an installable APK or run the application on a device.

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
Regenerate the checked-in legacy/adaptive PNG assets on Windows with
`.\tool\generate_android_icons.ps1` after changing `assets/tray/app_icon.png`.
