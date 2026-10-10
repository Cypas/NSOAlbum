import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'app_branding.dart';
import 'backend/storage_paths.dart';

const githubLatestReleaseApi =
    'https://api.github.com/repos/Cypas/NSOAlbum/releases/latest';
const _maxInstallerBytes = 512 * 1024 * 1024;

typedef ReleaseAssetCandidateBuilder = List<Uri> Function(Uri officialUrl);
typedef ReleaseApiCandidateBuilder = List<Uri> Function();

enum UpdateStatusKind { latest, available, failed }

class UpdateRequestAttempt {
  const UpdateRequestAttempt({required this.uri, required this.proxy});

  final String uri;
  final String? proxy;

  @override
  bool operator ==(Object other) =>
      other is UpdateRequestAttempt && other.uri == uri && other.proxy == proxy;

  @override
  int get hashCode => Object.hash(uri, proxy);
}

List<UpdateRequestAttempt> updateRequestAttempts({
  required List<String> apiCandidates,
  String? customProxyUrl,
}) {
  final attempts = <UpdateRequestAttempt>[
    for (final uri in apiCandidates)
      UpdateRequestAttempt(uri: uri, proxy: null),
  ];
  final proxy = _proxyDirective(customProxyUrl);
  if (proxy != null && apiCandidates.isNotEmpty) {
    attempts.add(UpdateRequestAttempt(uri: apiCandidates.last, proxy: proxy));
  }
  return attempts;
}

String? _proxyDirective(String? proxyUrl) {
  final value = proxyUrl?.trim();
  if (value == null || value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.hasScheme ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty) {
    return null;
  }
  final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
  return 'PROXY ${uri.host}:$port';
}

class StableRelease {
  const StableRelease({
    required this.version,
    required this.installerUrl,
    required this.sha256,
    this.assetName = '',
  });

  final String version;
  final Uri installerUrl;
  final String sha256;
  final String assetName;

  static StableRelease? fromGithubJson(Map<String, dynamic> json) {
    if (json['draft'] != false || json['prerelease'] != false) return null;
    final tag = json['tag_name'];
    if (tag is! String || !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag)) {
      return null;
    }
    final version = tag.substring(1);
    final assets = json['assets'];
    if (assets is! List) return null;
    for (final expectedAsset in [
      windowsInstallerName(version),
      'FreshAlbum-$version-Setup.exe',
    ]) {
      for (final entry in assets) {
        if (entry is! Map<String, dynamic> || entry['name'] != expectedAsset) {
          continue;
        }
        final url = entry['browser_download_url'];
        final digest = entry['digest'];
        if (url is! String || digest is! String) continue;
        final uri = Uri.tryParse(url);
        final match = RegExp(r'^sha256:([0-9a-fA-F]{64})$').firstMatch(digest);
        if (uri == null || uri.scheme != 'https' || uri.host != 'github.com') {
          continue;
        }
        if (uri.path !=
            '/Cypas/NSOAlbum/releases/download/$tag/$expectedAsset') {
          continue;
        }
        if (match == null) continue;
        return StableRelease(
          version: version,
          installerUrl: uri,
          sha256: match.group(1)!.toLowerCase(),
          assetName: expectedAsset,
        );
      }
    }
    return null;
  }
}

class LatestReleaseInfo {
  const LatestReleaseInfo({
    required this.version,
    required this.tag,
    required this.installer,
    this.body,
  });

  final String version;
  final String tag;
  final StableRelease? installer;
  final String? body;
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

LatestReleaseInfo? latestReleaseInfoFromGithubJson(
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
  return LatestReleaseInfo(
    version: version,
    tag: tag,
    installer: StableRelease.fromGithubJson(json),
    body: json['body'] is String ? json['body'] as String : null,
  );
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

bool automaticUpdateDateDue(String? lastDate, DateTime now) =>
    lastDate == null || lastDate != _localDateKey(now);

String _localDateKey(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

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
    String? applicationRoot,
    this.customProxyUrl,
    this._downloadDirectory,
  }) : _client = client ?? HttpClient(),
       _candidateBuilder = candidateBuilder ?? releaseAssetDownloadCandidates,
       _apiCandidateBuilder = apiCandidateBuilder ?? releaseApiCandidates,
       _applicationRootOverride = applicationRoot;

  final HttpClient _client;
  final ReleaseAssetCandidateBuilder _candidateBuilder;
  final ReleaseApiCandidateBuilder _apiCandidateBuilder;
  final Directory? _downloadDirectory;
  final String? _applicationRootOverride;
  final String? customProxyUrl;

  String? get _customProxyDirective => _proxyDirective(customProxyUrl);

  Future<bool> isAutomaticCheckDue() async {
    final support = await _applicationRoot();
    final timestampFile = File(
      '${support.path}${Platform.pathSeparator}update-check-v1.txt',
    );
    String? lastDate;
    try {
      lastDate = (await timestampFile.readAsString()).trim();
    } on FileSystemException {
      lastDate = null;
    }
    if (lastDate != null && DateTime.tryParse(lastDate) != null) {
      lastDate = _localDateKey(DateTime.parse(lastDate).toLocal());
    }
    return automaticUpdateDateDue(lastDate, DateTime.now());
  }

  Future<void> recordAutomaticCheck() async {
    final support = await _applicationRoot();
    final timestampFile = File(
      '${support.path}${Platform.pathSeparator}update-check-v1.txt',
    );
    final temporary = File('${timestampFile.path}.part');
    await temporary.writeAsString(_localDateKey(DateTime.now()), flush: true);
    if (await timestampFile.exists()) await timestampFile.delete();
    await temporary.rename(timestampFile.path);
  }

  Future<String?> ignoredReleaseVersion() async {
    final file = File(
      '${(await _applicationRoot()).path}${Platform.pathSeparator}ignored-release-version.txt',
    );
    try {
      final value = (await file.readAsString()).trim();
      return value.isEmpty ? null : value;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> ignoreReleaseVersion(String version) async {
    final file = File(
      '${(await _applicationRoot()).path}${Platform.pathSeparator}ignored-release-version.txt',
    );
    final temporary = File('${file.path}.part');
    await temporary.writeAsString(version, flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<StableRelease?> checkForUpdate(String currentVersion) async {
    final info = await checkLatestRelease(currentVersion);
    return info?.installer;
  }

  Future<LatestReleaseInfo?> checkLatestRelease(String currentVersion) async {
    Object? lastError;
    final candidates = _apiCandidateBuilder();
    final attempts = [
      ...candidates.map((uri) => (uri: uri, proxy: null as String?)),
      if (_customProxyDirective != null && candidates.isNotEmpty)
        (uri: candidates.last, proxy: _customProxyDirective),
    ];
    for (final attempt in attempts) {
      _setProxy(attempt.proxy);
      try {
        final request = await _client.getUrl(attempt.uri);
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/vnd.github+json',
        );
        request.headers.set(HttpHeaders.userAgentHeader, appEnglishName);
        request.headers.set('X-GitHub-Api-Version', '2022-11-28');
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        if (response.statusCode == HttpStatus.notFound) {
          await response.drain<void>();
          lastError = const FormatException(
            'No public stable release is available for $appEnglishName',
          );
          continue;
        }
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          throw HttpException(
            'Release lookup failed (HTTP ${response.statusCode})',
            uri: attempt.uri,
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
        return latestReleaseInfoFromGithubJson(decoded, currentVersion);
      } catch (error) {
        lastError = error;
      } finally {
        _setProxy(null);
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
          '${(await _applicationRoot()).path}${Platform.pathSeparator}updates',
    );
    await updateDirectory.create(recursive: true);
    final destination = File(
      '${updateDirectory.path}${Platform.pathSeparator}${windowsInstallerName(release.version)}',
    );
    Object? lastError;
    final candidates = _candidateBuilder(release.installerUrl);
    final attempts = [
      ...candidates.map((uri) => (uri: uri, proxy: null as String?)),
      if (_customProxyDirective != null && candidates.length > 1)
        (uri: candidates.last, proxy: _customProxyDirective),
    ];
    for (final attempt in attempts) {
      _setProxy(attempt.proxy);
      if (cancellation.isCancelled) {
        _setProxy(null);
        throw const UpdateCancelled();
      }
      final partial = File('${destination.path}.part');
      try {
        if (await partial.exists()) await partial.delete();
        final request = await _client.getUrl(attempt.uri);
        request.headers.set(HttpHeaders.userAgentHeader, appEnglishName);
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          throw HttpException(
            'Installer download failed (HTTP ${response.statusCode})',
            uri: attempt.uri,
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
        _setProxy(null);
        rethrow;
      } catch (error) {
        lastError = error;
        if (await partial.exists()) await partial.delete();
      } finally {
        _setProxy(null);
      }
    }
    throw StateError(
      'Unable to download a verified installer from the mirror or GitHub: $lastError',
    );
  }

  void _setProxy(String? proxy) {
    _client.findProxy = proxy == null ? (_) => 'DIRECT' : (_) => proxy;
  }

  Future<Directory> _applicationRoot() async {
    if (_applicationRootOverride != null) {
      final directory = Directory(_applicationRootOverride);
      await directory.create(recursive: true);
      return directory;
    }
    final support = await getApplicationSupportDirectory();
    final path = await resolveApplicationRoot(support.path);
    final directory = Directory(path);
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> close() async {
    _client.close(force: true);
  }
}
