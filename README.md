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

Windows packaging scripts are documented in [docs/README.md](docs/README.md). GitHub Actions validates pull requests and creates Windows packages plus an Apple Silicon macOS DMG for version tags.

## Releases and updates

Stable releases are published from tags in the form `v<major>.<minor>.<patch>`. The application version in `flutter_app/pubspec.yaml` is authoritative; the Rust crate version must use the same semantic version. Update checks query the latest stable release from `Cypas/NSOAlbum`. Windows release assets are the NSOAlbum runtime directory and `NSOAlbum-<version>-Setup.exe`; no ZIP package is generated. The installer is verified against the SHA-256 digest published by GitHub before the user can launch it. The app never installs an update silently.

macOS DMGs are currently unsigned and not notarized. Gatekeeper may require users to approve the app on first launch.

## License and assets

Original source code in this repository is offered under the [MIT License](LICENSE), unless a file or directory says otherwise. Third-party dependencies, fonts, and bundled media/artwork retain their own licenses or permissions; see [third-party notices](docs/legal/THIRD-PARTY-NOTICES.md) and the relevant asset directories. The MIT license does not grant rights to Nintendo trademarks or to third-party artwork and personal images.

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution and release conventions, and [SECURITY.md](SECURITY.md) for private vulnerability reporting guidance.
