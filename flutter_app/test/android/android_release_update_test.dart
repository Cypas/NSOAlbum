@Tags(['platform-android'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/release_update.dart';

Map<String, dynamic> metadata({Map<String, dynamic>? asset}) => {
  'tag_name': 'v0.3.0',
  'draft': false,
  'prerelease': false,
  'assets': [
    asset ??
        {
          'name': 'NSOAlbum-Android-arm64-0.3.0.apk',
          'browser_download_url': 'https://github.com/Cypas/NSOAlbum/releases/download/v0.3.0/NSOAlbum-Android-arm64-0.3.0.apk',
          'digest': 'sha256:${'A' * 64}',
          'size': 1024,
        },
  ],
};

void main() {
  test(
    'Android package uses matching official URL, digest and declared size',
    () {
      final release = latestReleaseInfoFromGithubJson(metadata(), '0.2.14+47')!;
      expect(release.androidPackage, isNotNull);
      expect(release.androidPackage!.version, '0.3.0');
      expect(release.androidPackage!.sha256, 'a' * 64);
      expect(release.androidPackage!.size, 1024);
      expect(release.installer, isNull);
    },
  );

  for (final entry in {
    'outside repository': {
      'browser_download_url': 'https://github.com/attacker/NSOAlbum/releases/download/v0.3.0/NSOAlbum-Android-arm64-0.3.0.apk',
    },
    'host suffix': {
      'browser_download_url': 'https://github.com.evil.invalid/Cypas/NSOAlbum/releases/download/v0.3.0/NSOAlbum-Android-arm64-0.3.0.apk',
    },
    'query': {
      'browser_download_url': 'https://github.com/Cypas/NSOAlbum/releases/download/v0.3.0/NSOAlbum-Android-arm64-0.3.0.apk?download=1',
    },
    'fragment': {
      'browser_download_url': 'https://github.com/Cypas/NSOAlbum/releases/download/v0.3.0/NSOAlbum-Android-arm64-0.3.0.apk#apk',
    },
    'credentials': {
      'browser_download_url': 'https://someone@github.com/Cypas/NSOAlbum/releases/download/v0.3.0/NSOAlbum-Android-arm64-0.3.0.apk',
    },
    'wrong ABI': {'name': 'NSOAlbum-Android-x64-0.3.0.apk'},
    'missing digest': {'digest': null},
    'malformed digest': {'digest': 'sha256:abc'},
    'missing size': {'size': null},
    'zero size': {'size': 0},
    'negative size': {'size': -1},
    'oversize': {'size': 512 * 1024 * 1024 + 1},
    'fractional size': {'size': 1024.5},
  }.entries) {
    test(
      'Android parser rejects ${entry.key} but retains release availability',
      () {
        final asset = Map<String, dynamic>.from(
          (metadata()['assets'] as List).single as Map,
        )..addAll(entry.value);
        final release = latestReleaseInfoFromGithubJson(
          metadata(asset: asset),
          '0.2.14',
        )!;
        expect(release.version, '0.3.0');
        expect(release.androidPackage, isNull);
      },
    );
  }

  test(
    'Android parser excludes drafts, prereleases and non-stable versions',
    () {
      for (final mutation in [
        {'draft': true},
        {'prerelease': true},
        {'tag_name': 'v0.3.0-beta.1'},
      ]) {
        expect(
          latestReleaseInfoFromGithubJson(
            metadata()..addAll(mutation),
            '0.2.14',
          ),
          isNull,
        );
      }
    },
  );

  test('missing Android asset remains visible without offering a package', () {
    final release = latestReleaseInfoFromGithubJson(
      metadata()..['assets'] = [],
      '0.2.14',
    );
    expect(release!.version, '0.3.0');
    expect(release.androidPackage, isNull);
  });
}
