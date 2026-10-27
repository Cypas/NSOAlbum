# Contributing

Thanks for helping improve NSOAlbum (鱿型相册 in Simplified Chinese). Please open an issue before undertaking a large feature so its behavior and platform scope can be agreed on.

## Pull requests

- Maintainers develop on `dev` and propose changes to `main` by pull request.
  Contributors may submit pull requests from forks. Do not directly push to
  `main`, force-push, or bypass the repository's branch protections.
- Keep changes focused and include tests for behavior changes. Before merging,
  satisfy the repository's current required checks and review requirements.
  Workflow triggers and platform gates are maintained in
  [the testing guide](docs/TESTING.md), not duplicated here.
- Rust remains the only owner of SQLite and content-addressed media files; Flutter talks to Rust through the generated bridge.
- Never add Nintendo session tokens, account data, local library databases, private proxy credentials, signing keys, or user media.
- Do not add developer-machine absolute paths to source or documentation.
- Run the Rust and Flutter checks in the root README before requesting review.
- If a bridge API or shared Rust/Dart DTO changes, regenerate bindings with `flutter_app/tool/generate_bridge.ps1`; do not hand-edit generated files.
- Keep the applicable product specification current when changing behavior, and
  summarize user-visible changes in the pull request and release notes.
- When checking a GitHub Actions run, wait for completion and review the full
  run, commit SHA, jobs, steps, and failure logs. Do not download workflow
  artifacts or package outputs while verifying CI; workflow jobs may transfer
  artifacts internally for automated checks.

## Versions and releases

`flutter_app/pubspec.yaml` is the application version source. Keep
`rust_core/Cargo.toml` on the same semantic version and keep generated release
metadata consistent. Stable tags use `v<major>.<minor>.<patch>` and are checked
against the source version. Update the changelog for user-visible changes.

Only maintainers create stable release tags. The Release workflow requires the
tagged commit to be merged into `main` and the complete validation gates to
succeed. For new releases, it builds a Windows Inno Setup installer, separate
arm64/x64 macOS DMGs, a signed ARM64 Android APK, and SHA-256 checksums.
Previously published releases may have a different asset set. macOS builds are
ad-hoc signed, not Developer ID signed or notarized. See
[the testing guide](docs/TESTING.md) for current platform checks and packaging
details.
