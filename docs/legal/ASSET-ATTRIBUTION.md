# Bundled artwork and other non-code assets

The repository's root MIT `LICENSE` applies to original source code only. It does not grant rights to Nintendo marks, game characters, photographs, tutorial screenshots, or other third-party artwork.

Known bundled assets:

- `flutter_app/assets/ci/synthetic-h264-aac.base64`: original synthetic 160×96 blue rectangle and silent audio, authored for this project's CI diagnostics (two-second H.264/AAC MP4). The generated media contains no user data and is dedicated to the public domain under CC0-1.0 by its creator; codec/encoder dependencies retain their own licenses.
- `flutter_app/assets/images/about/cypas_nya.jpg`: personal author/profile image supplied by the maintainer. Reuse outside this application requires the image rights holder's permission.
- `flutter_app/assets/tray/app_icon.png`, `flutter_app/assets/tray/app_icon.ico`, and `flutter_app/windows/runner/resources/app_icon.ico`: application icon artwork supplied by the maintainer. The maintainer must confirm redistribution rights before publishing a public release; the asset is not relicensed by MIT.
- `flutter_app/assets/images/import/import_step1.jpg`, `flutter_app/assets/images/import/import_step2.jpg`, and `flutter_app/assets/images/nintendo/nso_login_help.png`: user-provided instructional images. They are included for this application's onboarding and are not covered by the source-code license.
- `flutter_app/assets/fonts/SmileySans-Oblique.ttf`: third-party font distributed under the SIL Open Font License 1.1; see its adjacent license file.
- `flutter_app/assets/fonts/splatoon_web/`: Splatoon 1/2 webfont assets downloaded from the public `splatoon3.ink` asset bundle to reproduce its font-family and character-range fallback behavior. Registered Splatoon2 assets are decompressed to OpenType/TrueType for Flutter; original WOFF2 sources are retained. Format conversion does not change their licensing. These files are third-party assets and are not covered by MIT; verify Nintendo/rightsholder redistribution permission before publishing binaries.

The maintainer should verify the source and redistribution permission for each non-code image before enabling public binary releases. Nintendo and Kirby are trademarks/characters of their respective rights holders; NSOAlbum (鱿型相册 in Simplified Chinese) is an independent community project, not an official Nintendo product.
