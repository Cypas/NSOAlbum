# Bundled artwork and other non-code assets

The repository's root MIT `LICENSE` applies to original source code only. It does not grant rights to Nintendo marks, game characters, photographs, tutorial screenshots, or other third-party artwork.

Known bundled assets:

- `flutter_app/assets/ci/synthetic-h264-aac.base64`: original synthetic 160×96 blue rectangle and silent audio, authored for this project's CI diagnostics (two-second H.264/AAC MP4). The generated media contains no user data and is dedicated to the public domain under CC0-1.0 by its creator; codec/encoder dependencies retain their own licenses.
- `flutter_app/assets/images/about/cypas_nya.jpg`: personal author/profile image supplied by the maintainer. Reuse outside this application requires the image rights holder's permission.
- `flutter_app/assets/tray/app_icon.png`, `flutter_app/assets/tray/app_icon.ico`, and `flutter_app/windows/runner/resources/app_icon.ico`: application icon artwork supplied by the maintainer. This repository does not record a separate license for the artwork; its inclusion in existing source or binary releases does not establish or expand redistribution rights. Confirm and document the applicable permission for future distributions, or replace the asset if permission cannot be established.
- `flutter_app/assets/images/import/import_step1.jpg`, `flutter_app/assets/images/import/import_step2.jpg`, and `flutter_app/assets/images/nintendo/nso_login_help.png`: user-provided instructional images. They are included for this application's onboarding and are not covered by the source-code license.
- `flutter_app/assets/fonts/default/DFPT_ZY9.ttf`, `DFP_GBZY9.ttf`, and `BlitzMain.otf`: font files supplied by the maintainer and bundled as the current built-in UI font families. This repository does not record separate licenses for these files. Their inclusion in existing source or binary releases does not establish or expand redistribution rights; confirm and document the applicable permission for future distributions, or replace any asset whose permission cannot be established.

Historical font assets:

- Smiley Sans / 得意黑 is no longer kept as an active source font or bundled by the application. Its SIL Open Font License 1.1 notice is retained at `flutter_app/assets/fonts/SmileySans-OFL.txt`.
- Splatoon webfonts used in earlier font experiments are no longer kept as active source assets or bundled by the application. Historical files downloaded from the public `splatoon3.ink` asset bundle are not covered by MIT; their earlier presence in this repository does not grant redistribution rights. Nintendo/rightsholder permission must be verified before redistributing historical copies.

The maintainer should verify and document the source and redistribution permission for each non-code image used in future public distributions; existing publication does not grant additional rights. Nintendo and Kirby are trademarks/characters of their respective rights holders; NSOAlbum (鱿型相册 in Simplified Chinese) is an independent community project, not an official Nintendo product.
