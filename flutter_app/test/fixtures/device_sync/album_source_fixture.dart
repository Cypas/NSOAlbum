import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/state/settings_copy.dart';

import '../../home_shell_test.dart' show FakeBackend;

const longAlbumDeviceName =
    'Long desktop device name 日本語 1234567890 with another very long description';

FakeBackend albumSourceBackend({
  String language = 'zh',
  bool withMedia = false,
  bool longDeviceName = false,
}) {
  final backend = FakeBackend(
    mediaItems: withMedia ? null : [],
    albumItems: [
      AlbumSummary(
        id: 1,
        name: 'Favorites',
        description: '',
        albumType: 'smart',
        pinned: true,
        systemKey: 'favorites',
        mediaCount: BigInt.zero,
        sourceDeviceName: 'FAVORITES_SOURCE_MUST_NOT_APPEAR',
      ),
      for (final entry in [(2, 'Desktop'), (3, 'Phone')])
        AlbumSummary(
          id: entry.$1,
          name: 'Same name',
          description: '',
          albumType: 'manual',
          pinned: false,
          mediaCount: BigInt.zero,
          sourceDeviceName: entry.$1 == 2 && longDeviceName
              ? longAlbumDeviceName
              : entry.$2,
        ),
      AlbumSummary(
        id: 4,
        name: 'Unknown album',
        description: '',
        albumType: 'manual',
        pinned: false,
        mediaCount: BigInt.zero,
      ),
    ],
  );
  backend.settings = copyAppSettings(backend.settings, language: language);
  return backend;
}
