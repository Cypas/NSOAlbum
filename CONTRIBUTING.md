# Contributing

Thanks for helping improve NSOAlbum (鱿型相册 in Simplified Chinese). Please open an issue before undertaking a large feature so its behavior and platform scope can be agreed on.

## Pull requests

- Keep changes focused and include tests for behavior changes.
- Rust remains the only owner of SQLite and content-addressed media files; Flutter talks to Rust through the generated bridge.
- Never add Nintendo session tokens, account data, local library databases, private proxy credentials, signing keys, or user media.
- Do not add developer-machine absolute paths to source or documentation.
- Run the Rust and Flutter checks in the root README before requesting review.
- If a bridge API or shared Rust/Dart DTO changes, regenerate bindings with `flutter_app/tool/generate_bridge.ps1`; do not hand-edit generated files.
- Update `docs/design/nso-photo-design.md` when changing product behavior and `docs/CHANGELOG.md` for user-visible changes.

## Versions and releases

`flutter_app/pubspec.yaml` is the application version source. Keep `rust_core/Cargo.toml` on the same semantic version. Release tags use `v<major>.<minor>.<patch>` and must match both manifests; release automation rejects mismatches. Increment the Flutter build number for every distributable build and update the changelog.

Only maintainers create stable release tags. GitHub Actions produces a Windows runtime directory and Inno Setup installer, plus an Apple Silicon arm64 macOS DMG. ZIP release packages are not produced. macOS builds are currently unsigned and not notarized.
