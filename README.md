# NSOAlbum / 鱿型相册

NSOAlbum (鱿型相册 in Simplified Chinese) is a local-first media library for Nintendo Switch and Nintendo Switch 2 screenshots and videos. It can synchronize Nintendo Switch Online albums, import media over USB or from selected files, organize a local library, and export selected media.

This is an independent community project and is not affiliated with, endorsed by, or sponsored by Nintendo.

## Features

- Windows, macOS, and Android Flutter client with a Rust core.
- Local SQLite metadata and SHA-256 content-addressed media storage.
- Albums, favorites, game names, custom tags, notes, search, and video tools.
- Nintendo Account sync and Switch/Switch 2 USB media import.

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
[Testing and native release gates](docs/TESTING.md) distinguish portable tests,
platform-specific tests and real packaged-app diagnostics. GitHub Actions
validates Windows x64, macOS Apple Silicon arm64 and Intel x64 on their own
native runners before version-tag publication.

## Releases and updates

The current development version is `0.2.14+47` (Rust `0.2.14`); the latest
stable release is `v0.2.12`. Development work is performed on `dev` and merged
to `main` by pull request. The full native validation matrix is required for
the pull request and for release publication; a failed or cancelled platform
gate blocks the merge/release.

To test packaging without changing the version or creating a tag, run the
**Validate** workflow manually with `package_installer=true` and an optional
`ref` (branch or commit). It runs the same signing, testing and packaged-app
checks and uploads the Windows installer and both macOS DMGs as Actions
artifacts, without creating a GitHub Release:

```sh
gh workflow run validate.yml --ref dev \
  -f ref=dev -f package_installer=true
```

Stable releases are published from tags in the form `v<major>.<minor>.<patch>`. The application version in `flutter_app/pubspec.yaml` is authoritative; the Rust crate version must use the same semantic version. Update checks query the latest stable release from `Cypas/NSOAlbum`. CI produces a Windows runtime directory for validation and packaging; the public GitHub Release publishes `NSOAlbum-<version>-Setup.exe`, the arm64/x64 macOS DMGs, and `SHA256SUMS.txt`. No ZIP package is generated. The installer is verified against the SHA-256 digest published by GitHub before the user can launch it. The app never installs an update silently.

`main` is the default stable branch. Maintainers develop on `dev` and merge
`dev` into `main` through pull requests after `Required validation` succeeds.
Pushes to `dev` run the faster Ubuntu Rust/Flutter checks and history scan;
the full Windows/macOS native matrix runs on the pull request, `main` pushes,
manual packaging checks and stable release tags. Stable release tags must
point to commits already merged into `main`.

Upgrades reuse an existing library in `NSOAlbum`, `Fresh Album`, `FreshAlbum`, or
`squid_album` application data directories when a valid database is found. The
application does not copy or delete legacy media during this detection. Releases
from `0.2.9` onward publish only the canonical
`NSOAlbum-<version>-Setup.exe` installer asset.

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
Every platform must pass its full Rust/Flutter suite, real image/video playback,
FFmpeg cover/duration, trim/merge, and isolated-library restart checks before
publication. No real Nintendo credentials or personal media are used by CI.

## License and assets

Original source code in this repository is offered under the [MIT License](LICENSE), unless a file or directory says otherwise. Third-party dependencies, fonts, and bundled media/artwork retain their own licenses or permissions; see [third-party notices](docs/legal/THIRD-PARTY-NOTICES.md) and the relevant asset directories. The MIT license does not grant rights to Nintendo trademarks or to third-party artwork and personal images.

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution and release conventions, and [SECURITY.md](SECURITY.md) for private vulnerability reporting guidance.
