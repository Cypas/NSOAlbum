import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

const githubLatestReleaseApi =
    'https://api.github.com/repos/Cypas/NSOAlbum/releases/latest';
const _maxInstallerBytes = 512 * 1024 * 1024;

typedef ReleaseAssetCandidateBuilder = List<Uri> Function(Uri officialUrl);
typedef ReleaseApiCandidateBuilder = List<Uri> Function();

class StableRelease {
  const StableRelease({
    required this.version,
    required this.installerUrl,
    required this.sha256,
  });

  final String version;
  final Uri installerUrl;
  final String sha256;

  static StableRelease? fromGithubJson(Map<String, dynamic> json) {
    if (json['draft'] != false || json['prerelease'] != false) return null;
    final tag = json['tag_name'];
    if (tag is! String || !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag)) {
      return null;
    }
    final version = tag.substring(1);
    final expectedAsset = 'FreshAlbum-$version-Setup.exe';
    final assets = json['assets'];
    if (assets is! List) return null;
    for (final entry in assets) {
      if (entry is! Map<String, dynamic> || entry['name'] != expectedAsset) {
        continue;
      }
      final url = entry['browser_download_url'];
      final digest = entry['digest'];
      if (url is! String || digest is! String) return null;
      final uri = Uri.tryParse(url);
      final match = RegExp(r'^sha256:([0-9a-fA-F]{64})$').firstMatch(digest);
      if (uri == null || uri.scheme != 'https' || uri.host != 'github.com') {
        return null;
      }
      if (uri.path != '/Cypas/NSOAlbum/releases/download/$tag/$expectedAsset') {
        return null;
      }
      if (match == null) return null;
      return StableRelease(
        version: version,
        installerUrl: uri,
        sha256: match.group(1)!.toLowerCase(),
      );
    }
    return null;
  }
}

int compareStableVersions(String left, String right) {
  List<int> parts(String value) {
    final withoutBuild = value.replaceFirst(RegExp(r'\+.*$'), '');
    final normalized = withoutBuild.replaceFirst(RegExp(r'^v'), '');
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(normalized);
    if (match == null) {
      throw FormatException('Expected a stable semantic version', value);
    }
    return [
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    ];
  }

  final leftParts = parts(left);
  final rightParts = parts(right);
  for (var index = 0; index < 3; index++) {
    final compared = leftParts[index].compareTo(rightParts[index]);
    if (compared != 0) return compared;
  }
  return 0;
}

StableRelease? latestStableUpdateFromGithubJson(
  Map<String, dynamic> json,
  String currentVersion,
) {
  if (json['draft'] != false || json['prerelease'] != false) return null;
  final tag = json['tag_name'];
  if (tag is! String || !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag)) {
    return null;
  }
  final version = tag.substring(1);
  if (compareStableVersions(currentVersion, version) >= 0) return null;
  final release = StableRelease.fromGithubJson(json);
  if (release == null) {
    throw const FormatException(
      'A newer stable release does not contain a verifiable Windows installer',
    );
  }
  return release;
}

List<Uri> releaseAssetDownloadCandidates(Uri officialUrl) => [
  Uri.parse('https://gh-proxy.org/$officialUrl'),
  officialUrl,
];

List<Uri> releaseApiCandidates() => [
  Uri.parse('https://gh-proxy.org/$githubLatestReleaseApi'),
  Uri.parse(githubLatestReleaseApi),
];

bool automaticUpdateCheckDue(DateTime? lastCheck, DateTime now) =>
    lastCheck == null || now.difference(lastCheck) >= const Duration(days: 1);

Future<bool> verifyInstallerSha256(File file, String expectedSha256) async {
  final expected = expectedSha256.toLowerCase().replaceFirst('sha256:', '');
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expected)) return false;
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString() == expected;
}

class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

class UpdateCancellation {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class ReleaseUpdateService {
  ReleaseUpdateService({
    HttpClient? client,
    ReleaseAssetCandidateBuilder? candidateBuilder,
    ReleaseApiCandidateBuilder? apiCandidateBuilder,
    this._downloadDirectory,
  }) : _client = client ?? HttpClient(),
       _candidateBuilder = candidateBuilder ?? releaseAssetDownloadCandidates,
       _apiCandidateBuilder = apiCandidateBuilder ?? releaseApiCandidates;

  final HttpClient _client;
  final ReleaseAssetCandidateBuilder _candidateBuilder;
  final ReleaseApiCandidateBuilder _apiCandidateBuilder;
  final Directory? _downloadDirectory;

  Future<bool> isAutomaticCheckDue() async {
    final support = await getApplicationSupportDirectory();
    final timestampFile = File(
      '${support.path}${Platform.pathSeparator}update-check-v1.txt',
    );
    DateTime? lastCheck;
    try {
      lastCheck = DateTime.tryParse(await timestampFile.readAsString());
    } on FileSystemException {
      lastCheck = null;
    }
    return automaticUpdateCheckDue(lastCheck, DateTime.now().toUtc());
  }

  Future<void> recordAutomaticCheck() async {
    final support = await getApplicationSupportDirectory();
    final timestampFile = File(
      '${support.path}${Platform.pathSeparator}update-check-v1.txt',
    );
    final temporary = File('${timestampFile.path}.part');
    await temporary.writeAsString(
      DateTime.now().toUtc().toIso8601String(),
      flush: true,
    );
    if (await timestampFile.exists()) await timestampFile.delete();
    await temporary.rename(timestampFile.path);
  }

  Future<StableRelease?> checkForUpdate(String currentVersion) async {
    Object? lastError;
    for (final uri in _apiCandidateBuilder()) {
      try {
        final request = await _client.getUrl(uri);
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/vnd.github+json',
        );
        request.headers.set(HttpHeaders.userAgentHeader, 'FreshAlbum');
        request.headers.set('X-GitHub-Api-Version', '2022-11-28');
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        if (response.statusCode == HttpStatus.notFound) {
          await response.drain<void>();
          lastError = const FormatException(
            'No public stable release is available for Fresh Album',
          );
          continue;
        }
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          throw HttpException(
            'Release lookup failed (HTTP ${response.statusCode})',
            uri: uri,
          );
        }
        final body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 15));
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException(
            'Release service returned invalid metadata',
          );
        }
        return latestStableUpdateFromGithubJson(decoded, currentVersion);
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError ??
        const FormatException('No release service could be reached');
  }

  Future<File> downloadInstaller(
    StableRelease release, {
    required UpdateCancellation cancellation,
    void Function(int received, int? total)? onProgress,
  }) async {
    final updateDirectory = Directory(
      _downloadDirectory?.path ??
          '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}FreshAlbumUpdates',
    );
    await updateDirectory.create(recursive: true);
    final destination = File(
      '${updateDirectory.path}${Platform.pathSeparator}FreshAlbum-${release.version}-Setup.exe',
    );
    Object? lastError;
    for (final uri in _candidateBuilder(release.installerUrl)) {
      if (cancellation.isCancelled) throw const UpdateCancelled();
      final partial = File('${destination.path}.part');
      try {
        if (await partial.exists()) await partial.delete();
        final request = await _client.getUrl(uri);
        request.headers.set(HttpHeaders.userAgentHeader, 'FreshAlbum');
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          throw HttpException(
            'Installer download failed (HTTP ${response.statusCode})',
            uri: uri,
          );
        }
        if (response.contentLength > _maxInstallerBytes) {
          await response.drain<void>();
          throw const FormatException('Installer exceeds the 512 MiB limit');
        }
        final sink = partial.openWrite();
        var received = 0;
        try {
          await for (final chunk in response.timeout(
            const Duration(seconds: 60),
          )) {
            if (cancellation.isCancelled) throw const UpdateCancelled();
            received += chunk.length;
            if (received > _maxInstallerBytes) {
              throw const FormatException(
                'Installer exceeds the 512 MiB limit',
              );
            }
            sink.add(chunk);
            onProgress?.call(
              received,
              response.contentLength < 0 ? null : response.contentLength,
            );
          }
          if (cancellation.isCancelled) throw const UpdateCancelled();
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (!await verifyInstallerSha256(partial, release.sha256)) {
          throw const FormatException('Installer SHA-256 verification failed');
        }
        if (await destination.exists()) await destination.delete();
        return await partial.rename(destination.path);
      } on UpdateCancelled {
        if (await partial.exists()) await partial.delete();
        rethrow;
      } catch (error) {
        lastError = error;
        if (await partial.exists()) await partial.delete();
      }
    }
    throw StateError(
      'Unable to download a verified installer from the mirror or GitHub: $lastError',
    );
  }

  Future<void> close() async {
    _client.close(force: true);
  }
}
