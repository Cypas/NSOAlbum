import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/app_backend.dart';
import 'package:squid_album/src/backend/mobile_storage_policy.dart';

void main() {
  test(
    'existing private legacy paths stay valid but absent SD never falls back',
    () {
      expect(
        mobileStorageIsAvailable(
          libraryPath: '/private/NSOAlbum/squid_album_library/media',
          applicationRoot: '/private/NSOAlbum',
          locations: const [],
        ),
        isTrue,
      );
      expect(
        mobileStorageIsAvailable(
          libraryPath: '/storage/card/app/NSOAlbum/media',
          applicationRoot: '/private/NSOAlbum',
          locations: const [
            MobileStorageLocation(
              id: 'internal',
              path: '/private/NSOAlbum/media',
              removable: false,
            ),
          ],
        ),
        isFalse,
      );
    },
  );
  test(
    'mounted removable location must match exactly, with no prefix escape',
    () {
      const locations = [
        MobileStorageLocation(
          id: 'sd',
          path: '/storage/card/app/NSOAlbum/media',
          removable: true,
        ),
      ];
      expect(
        mobileStorageIsAvailable(
          libraryPath: '/storage/card/app/NSOAlbum/media',
          applicationRoot: '/private/NSOAlbum',
          locations: locations,
        ),
        isTrue,
      );
      for (final path in [
        '/private/NSOAlbum-other/media',
        '/private/NSOAlbum/../../elsewhere',
      ]) {
        expect(
          mobileStorageIsAvailable(
            libraryPath: path,
            applicationRoot: '/private/NSOAlbum',
            locations: locations,
          ),
          isFalse,
        );
      }
    },
  );
}
