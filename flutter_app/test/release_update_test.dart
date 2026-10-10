import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/app_branding.dart';
import 'package:squid_album/src/release_update.dart';

Uri _serverUri(HttpServer server) => Uri(
  scheme: 'http',
  host: server.address.address,
  port: server.port,
  path: '/',
);

void main() {
  test('installer release asset name follows NSOAlbum branding', () {
    expect(windowsInstallerName('0.2.0'), 'NSOAlbum-0.2.0-Setup.exe');
  });

  test('stable version comparison ignores build metadata', () {
    expect(compareStableVersions('0.1.29+30', 'v0.2.0'), lessThan(0));
    expect(compareStableVersions('1.2.0', 'v1.2.0'), 0);
    expect(compareStableVersions('1.10.0', 'v1.9.9'), greaterThan(0));
  });

  test('release metadata requires stable tag and SHA-256 installer asset', () {
    final release = StableRelease.fromGithubJson({
      'tag_name': 'v0.2.0',
      'draft': false,
      'prerelease': false,
      'assets': [
        {
          'name': 'NSOAlbum-0.2.0-Setup.exe',
          'browser_download_url': 'https://github.com/Cypas/NSOAlbum/releases/download/v0.2.0/NSOAlbum-0.2.0-Setup.exe',
          'digest': 'sha256:${'a' * 64}',
        },
      ],
    });

    expect(release, isNotNull);
    expect(release!.version, '0.2.0');
    expect(release.sha256, 'a' * 64);
    expect(
      StableRelease.fromGithubJson({
        'tag_name': 'v0.3.0-beta.1',
        'draft': false,
        'prerelease': true,
        'assets': const [],
      }),
      isNull,
    );
  });

  test('release metadata accepts the legacy FreshAlbum installer name', () {
    final release = StableRelease.fromGithubJson({
      'tag_name': 'v0.2.7',
      'draft': false,
      'prerelease': false,
      'assets': [
        {
          'name': 'FreshAlbum-0.2.7-Setup.exe',
          'browser_download_url': 'https://github.com/Cypas/NSOAlbum/releases/download/v0.2.7/FreshAlbum-0.2.7-Setup.exe',
          'digest': 'sha256:${'b' * 64}',
        },
      ],
    });

    expect(release, isNotNull);
    expect(release!.assetName, 'FreshAlbum-0.2.7-Setup.exe');
  });

  test(
    'new release metadata remains visible when installer is unavailable',
    () {
      final info = latestReleaseInfoFromGithubJson({
        'tag_name': 'v0.2.7',
        'draft': false,
        'prerelease': false,
        'body': 'notes',
        'assets': const [],
      }, '0.2.0+31');

      expect(info, isNotNull);
      expect(info!.version, '0.2.7');
      expect(info.installer, isNull);
    },
  );

  test(
    'release parser rejects an asset URL outside the expected repository',
    () {
      expect(
        StableRelease.fromGithubJson({
          'tag_name': 'v0.2.0',
          'draft': false,
          'prerelease': false,
          'assets': [
            {
              'name': 'NSOAlbum-0.2.0-Setup.exe',
              'browser_download_url': 'https://github.com/attacker/other/releases/download/v0.2.0/NSOAlbum-0.2.0-Setup.exe',
              'digest': 'sha256:${'a' * 64}',
            },
          ],
        }),
        isNull,
      );
    },
  );

  test('newer release without a trusted installer digest is rejected', () {
    expect(
      () => latestStableUpdateFromGithubJson({
        'tag_name': 'v0.2.0',
        'draft': false,
        'prerelease': false,
        'assets': [
          {
            'name': 'NSOAlbum-0.2.0-Setup.exe',
            'browser_download_url': 'https://github.com/Cypas/NSOAlbum/releases/download/v0.2.0/NSOAlbum-0.2.0-Setup.exe',
          },
        ],
      }, '0.1.29+30'),
      throwsFormatException,
    );
  });

  test('release asset candidates try the proxy before the official URL', () {
    final candidates = releaseAssetDownloadCandidates(
      Uri.parse(
        'https://github.com/Cypas/NSOAlbum/releases/download/v0.2.0/app.exe',
      ),
    );

    expect(candidates.first.host, 'gh-proxy.org');
    expect(candidates.last.host, 'github.com');
  });

  test('release API candidates try the proxy before GitHub', () {
    final candidates = releaseApiCandidates();
    expect(candidates.first.host, 'gh-proxy.org');
    expect(candidates.last.host, 'api.github.com');
  });

  test('custom update proxy is used only after direct candidates fail', () {
    expect(
      updateRequestAttempts(
        apiCandidates: const [
          'https://gh-proxy.org/api',
          'https://api.github.com/api',
        ],
        customProxyUrl: 'http://127.0.0.1:7890',
      ),
      [
        const UpdateRequestAttempt(
          uri: 'https://gh-proxy.org/api',
          proxy: null,
        ),
        const UpdateRequestAttempt(
          uri: 'https://api.github.com/api',
          proxy: null,
        ),
        const UpdateRequestAttempt(
          uri: 'https://api.github.com/api',
          proxy: 'PROXY 127.0.0.1:7890',
        ),
      ],
    );
  });

  test('custom HTTPS proxy gets its default port', () {
    final attempts = updateRequestAttempts(
      apiCandidates: const ['https://api.github.com/releases/latest'],
      customProxyUrl: 'https://proxy.example',
    );
    expect(attempts.last.proxy, 'PROXY proxy.example:443');
  });

  test(
    'custom proxy serves release metadata after both direct lookups fail',
    () async {
      final mirror = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final github = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final customProxy = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() async {
        await mirror.close(force: true);
        await github.close(force: true);
        await customProxy.close(force: true);
      });
      var mirrorRequests = 0;
      var githubRequests = 0;
      var proxyRequests = 0;
      mirror.listen((request) async {
        mirrorRequests++;
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
      });
      github.listen((request) async {
        githubRequests++;
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
      });
      customProxy.listen((request) async {
        proxyRequests++;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'tag_name': 'v0.2.7',
            'draft': false,
            'prerelease': false,
            'assets': const [],
          }),
        );
        await request.response.close();
      });
      final service = ReleaseUpdateService(
        apiCandidateBuilder: () => [_serverUri(mirror), _serverUri(github)],
        customProxyUrl: _serverUri(customProxy).toString(),
      );
      addTearDown(service.close);

      final release = await service.checkLatestRelease('0.2.7');

      expect(release, isNull);
      expect(mirrorRequests, 1);
      expect(githubRequests, 1);
      expect(proxyRequests, 1);
    },
  );

  test('custom proxy downloads installer after mirror and GitHub fail', () async {
    final mirror = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final github = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final customProxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final directory = await Directory.systemTemp.createTemp(
      'nso-album-proxy-update-test-',
    );
    addTearDown(() async {
      await mirror.close(force: true);
      await github.close(force: true);
      await customProxy.close(force: true);
      await directory.delete(recursive: true);
    });
    var mirrorRequests = 0;
    var githubRequests = 0;
    var proxyRequests = 0;
    mirror.listen((request) async {
      mirrorRequests++;
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
    });
    github.listen((request) async {
      githubRequests++;
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
    });
    final bytes = 'installer through custom proxy'.codeUnits;
    customProxy.listen((request) async {
      proxyRequests++;
      request.response.add(bytes);
      await request.response.close();
    });
    final service = ReleaseUpdateService(
      downloadDirectory: directory,
      candidateBuilder: (_) => [_serverUri(mirror), _serverUri(github)],
      customProxyUrl: _serverUri(customProxy).toString(),
    );
    addTearDown(service.close);

    final installer = await service.downloadInstaller(
      StableRelease(
        version: '0.2.7',
        installerUrl: Uri.parse(
          'https://github.com/Cypas/NSOAlbum/releases/download/v0.2.7/NSOAlbum-0.2.7-Setup.exe',
        ),
        sha256:
            '041835a5fb1e68f422c30c6baa4c6ef67c6d0c4a97bc0996ce0a0905561a25c3',
      ),
      cancellation: UpdateCancellation(),
    );

    expect(await installer.readAsBytes(), bytes);
    expect(mirrorRequests, 1);
    expect(githubRequests, 1);
    expect(proxyRequests, 1);
  });

  test('automatic checks are limited to once in a 24 hour window', () {
    final now = DateTime.utc(2026, 10, 7, 12);

    expect(automaticUpdateCheckDue(null, now), isTrue);
    expect(
      automaticUpdateCheckDue(now.subtract(const Duration(hours: 23)), now),
      isFalse,
    );
    expect(
      automaticUpdateCheckDue(now.subtract(const Duration(days: 1)), now),
      isTrue,
    );
  });

  test('installer checksum verifies bytes from disk', () async {
    final file = File(
      '${Directory.systemTemp.path}/fresh-album-hash-test-$pid.bin',
    );
    await file.writeAsBytes('release bytes'.codeUnits);
    addTearDown(() => file.delete());

    expect(
      await verifyInstallerSha256(
        file,
        'ff7a5e6429d2c8511521e4abf41cd54a3e525ef4a1f24f8d1c67ede9d17874dd',
      ),
      isTrue,
    );
  });

  test('installer download falls back to GitHub after mirror failure', () async {
    final mirror = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final github = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final directory = await Directory.systemTemp.createTemp(
      'fresh-album-update-test-',
    );
    addTearDown(() async {
      await mirror.close(force: true);
      await github.close(force: true);
      await directory.delete(recursive: true);
    });
    mirror.listen((request) async {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
    });
    final bytes = 'release bytes'.codeUnits;
    github.listen((request) async {
      request.response.add(bytes);
      await request.response.close();
    });
    final service = ReleaseUpdateService(
      downloadDirectory: directory,
      candidateBuilder: (_) => [_serverUri(mirror), _serverUri(github)],
    );
    addTearDown(service.close);

    final installer = await service.downloadInstaller(
      StableRelease(
        version: '0.2.0',
        installerUrl: Uri.parse(
          'https://github.com/Cypas/NSOAlbum/releases/download/v0.2.0/NSOAlbum-0.2.0-Setup.exe',
        ),
        sha256:
            'ff7a5e6429d2c8511521e4abf41cd54a3e525ef4a1f24f8d1c67ede9d17874dd',
      ),
      cancellation: UpdateCancellation(),
    );

    expect(await installer.readAsBytes(), bytes);
    expect(installer.path, contains('NSOAlbum-0.2.0-Setup.exe'));
  });

  test('cancelling a download removes its partial installer', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final directory = await Directory.systemTemp.createTemp(
      'fresh-album-update-cancel-',
    );
    addTearDown(() async {
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    server.listen((request) async {
      request.response.add('partial bytes'.codeUnits);
      await request.response.flush();
      await request.response.close();
    });
    final service = ReleaseUpdateService(
      downloadDirectory: directory,
      candidateBuilder: (_) => [_serverUri(server)],
    );
    addTearDown(service.close);
    final cancellation = UpdateCancellation();

    await expectLater(
      service.downloadInstaller(
        StableRelease(
          version: '0.2.0',
          installerUrl: Uri.parse(
            'https://github.com/Cypas/NSOAlbum/releases/download/v0.2.0/NSOAlbum-0.2.0-Setup.exe',
          ),
          sha256: '0' * 64,
        ),
        cancellation: cancellation,
        onProgress: (_, _) => cancellation.cancel(),
      ),
      throwsA(isA<UpdateCancelled>()),
    );
    expect(await directory.list().isEmpty, isTrue);
  });
}
