# NSOAlbum / 鱿型相册

NSOAlbum (鱿型相册 in Simplified Chinese) is a local-first media library for Nintendo Switch and Nintendo Switch 2 screenshots and videos. It can synchronize Nintendo Switch Online albums, import media over USB or from selected files, organize a local library, and export selected media.

This is an independent community project and is not affiliated with, endorsed by, or sponsored by Nintendo.

## Features

- Windows, macOS, and Android Flutter client with a Rust core.
- Local SQLite metadata and SHA-256 content-addressed media storage.
- Albums, favorites, game names, custom tags, notes, search, export, and video tools.
- Nintendo Account album sync, account-specific friend tools, and optional device-to-device sync.
- Desktop Switch / Switch 2 USB import and user-selected file or folder import.

Nintendo's services and community attestation providers are third-party services. Their availability and terms can change. Review [third-party notices](docs/legal/THIRD-PARTY-NOTICES.md) and [asset permissions](docs/legal/ASSET-ATTRIBUTION.md) before building or redistributing the application. Internal protocol research and product design notes are not included in this public source tree.

## Development

Requirements:

- Flutter and Dart versions compatible with `flutter_app/pubspec.yaml`.
- Rust stable toolchain.
- Windows builds additionally require Visual Studio C++ Build Tools and Windows SDK.
- macOS builds require Xcode.

Run Rust checks:

```sh
cd rust_core
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test --lib
```

Run Flutter checks:

```sh
cd flutter_app
dart analyze
flutter test
```

Generate Flutter/Rust bindings after changing the bridge or shared DTOs:

```powershell
cd flutter_app
.\tool\generate_bridge.ps1
```

Windows packaging scripts are documented in [docs/README.md](docs/README.md).
The [documentation map](docs/DOCUMENTATION-MAP.md) explains nested READMEs,
third-party notices and local-only records; the
[repository layout](docs/REPOSITORY-LAYOUT.md) defines file locations and Git ignore boundaries.
[Testing and native release gates](docs/TESTING.md) distinguish portable tests,
platform-specific tests and real packaged-app diagnostics. GitHub Actions
validates Windows x64, macOS Apple Silicon arm64 and Intel x64 on native
runners, and performs Android ARM64 build and package checks. Static Android
checks do not claim on-device acceptance.

## Releases and updates

This source checkout is version `0.2.15+48` (Rust `0.2.15`). As of
October 25, 2026, the latest published stable release is `v0.2.14`; a
development version is not a stable release. Development work is performed on
`dev` and proposed for `main` by pull request.

Pushes to `dev` run the fast Ubuntu checks and history scan. Pull requests
targeting `main` and pushes to `main` run the full validation workflow, including
the native Windows, macOS and Android gates. Stable release publication has
additional tag and `main` ancestry checks.

To run full validation on demand without publishing a release, start the
**Validate** workflow with an optional exact `ref`. Set `package_installer=true`
when the run should also build distribution packages as workflow artifacts:

```sh
gh workflow run validate.yml --ref dev \
  -f ref=dev -f package_installer=true
```

The application version in `flutter_app/pubspec.yaml` is authoritative; the
Rust crate uses the same semantic version. Stable releases use tags in the form
`v<major>.<minor>.<patch>`. On successful publication, the Release workflow
produces the Windows Inno Setup installer, separate Apple Silicon arm64 and
Intel x64 macOS DMGs, an ARM64 Android APK, and `SHA256SUMS.txt`. No ZIP package
is generated. The existing `v0.2.14` release predates Android APK publication.
The Windows installer is verified against its published SHA-256 digest before
an update can be installed; updates are never installed silently.

For CI verification, wait for the complete workflow and review its pinned
commit, final result, jobs, steps, and failure logs. Do not judge success from
an individual job or artifact. Do not download workflow artifacts or package
outputs while verifying CI results; workflow jobs may transfer artifacts
internally for automated checks.

Upgrades reuse an existing library in `NSOAlbum`, `Fresh Album`, `FreshAlbum`, or
`squid_album` application data directories when a valid database is found. The
application does not copy or delete legacy media during this detection. The
Windows installer uses the canonical asset name
`NSOAlbum-<version>-Setup.exe`.

The current Android application ID is `io.github.cypas.nsoalbum`. The older
`io.squidalbum.squid_album` package is a separate app installation; installing
the current app does not automatically uninstall the old app or migrate its
private app data.

macOS DMGs are distributed separately for arm64 and Intel x64, outside the App
Sandbox, with ad-hoc integrity signatures. They are not Developer ID signed or
notarized; Gatekeeper may require users to approve the app on first launch.
macOS checks for stable releases at most once per local calendar day on normal
Release startup, with a manual check in About. Update prompts show release notes
and whether a DMG exists for the running architecture. "Go to downloads" opens
the project's GitHub Releases page in the default browser; macOS never downloads
or replaces the app automatically. Quit the app and install the appropriate
arm64 or Intel x64 DMG manually. Dismissing a prompt postpones it; ignoring a
version suppresses only that version's automatic prompt. Manual checks bypass
the daily limit and ignored-version preference. Safe mode and CI smoke do not
perform automatic update checks.
Each required platform gate must pass the checks defined in
[Testing and native release gates](docs/TESTING.md) before publication. CI uses
synthetic data and does not use real Nintendo credentials or personal media.

## License and assets

Original source code in this repository is offered under the [MIT License](LICENSE), unless a file or directory says otherwise. Third-party dependencies, fonts, and bundled media/artwork retain their own licenses or permissions; see [third-party notices](docs/legal/THIRD-PARTY-NOTICES.md) and the relevant asset directories. The MIT license does not grant rights to Nintendo trademarks or to third-party artwork and personal images.

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution and release conventions, and [SECURITY.md](SECURITY.md) for private vulnerability reporting guidance.
