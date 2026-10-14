import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_version.dart';
import '../release_update.dart';

enum AndroidUpdateAction { later, ignore, download }

enum AndroidUpdateState { idle, downloading, verifying, ready, failed }

bool androidUpdateStartupEnabled({
  required bool isAndroid,
  required bool releaseMode,
  required bool isTest,
  required bool safeMode,
  required bool ciSmoke,
}) => isAndroid && releaseMode && !isTest && !safeMode && !ciSmoke;

class AndroidUpdateStatus {
  const AndroidUpdateStatus({
    this.state = AndroidUpdateState.idle,
    this.version,
    this.received = 0,
    this.total = 0,
    this.error,
    this.notificationAllowed = false,
  });

  final AndroidUpdateState state;
  final String? version;
  final int received;
  final int total;
  final String? error;
  final bool notificationAllowed;

  bool get busy =>
      state == AndroidUpdateState.downloading ||
      state == AndroidUpdateState.verifying;

  factory AndroidUpdateStatus.fromNative(Object? value) {
    if (value is! Map) throw const FormatException('Invalid update status');
    final state = AndroidUpdateState.values
        .where((item) => item.name == value['state'])
        .firstOrNull;
    if (state == null) throw const FormatException('Invalid update state');
    final received = value['received'];
    final total = value['total'];
    return AndroidUpdateStatus(
      state: state,
      version: value['version'] is String ? value['version'] as String : null,
      received: received is int && received >= 0 ? received : 0,
      total: total is int && total >= 0 ? total : 0,
      error: value['error'] is String ? value['error'] as String : null,
      notificationAllowed: value['notificationAllowed'] == true,
    );
  }
}

/// Flutter owns consent and display only; Android owns the persisted APK task.
class AndroidUpdateController extends ChangeNotifier {
  AndroidUpdateController({
    ReleaseUpdateService? releaseService,
    this.channel = const MethodChannel('io.github.cypas.nsoalbum/update'),
    Future<String> Function()? versionLoader,
    String? applicationRoot,
  }) : _service =
           releaseService ??
           ReleaseUpdateService(
             applicationRoot: applicationRoot,
             apiCandidateBuilder: () => [Uri.parse(githubLatestReleaseApi)],
           ),
       _versionLoader = versionLoader ?? loadApplicationVersion;

  final ReleaseUpdateService _service;
  final MethodChannel channel;
  final Future<String> Function() _versionLoader;
  AndroidUpdateStatus status = const AndroidUpdateStatus();
  LatestReleaseInfo? latestRelease;
  UpdateStatusKind? updateStatus;
  bool checking = false;
  bool installing = false;
  bool _starting = false;
  bool _restoring = false;
  bool _disposed = false;
  bool _foreground = true;
  String? _operationError;
  Timer? _poll;

  bool get canDownload =>
      latestRelease?.androidPackage != null &&
      !status.busy &&
      status.state != AndroidUpdateState.ready &&
      !_starting;
  bool get canInstall =>
      status.state == AndroidUpdateState.ready && !installing;

  Future<void> check({
    required bool automatic,
    required String language,
    required Future<AndroidUpdateAction?> Function(LatestReleaseInfo) confirm,
  }) async {
    if (_disposed || checking || status.busy || _starting) return;
    if (automatic && status.state == AndroidUpdateState.ready) return;
    checking = true;
    _notify();
    try {
      if (automatic) {
        if (!await _service.isAutomaticCheckDue()) return;
        await _service.recordAutomaticCheck();
      }
      final currentVersion = await _versionLoader();
      if (_disposed) return;
      final release = await _service.checkLatestRelease(currentVersion);
      if (_disposed) return;
      latestRelease = release;
      updateStatus = release == null
          ? UpdateStatusKind.latest
          : UpdateStatusKind.available;
      _operationError = null;
      _notify();
      if (release == null) return;
      if (automatic &&
          await _service.ignoredReleaseVersion() == release.version) {
        return;
      }
      if (_disposed) return;
      final action = await confirm(release);
      if (_disposed) return;
      switch (action) {
        case AndroidUpdateAction.ignore:
          await _service.ignoreReleaseVersion(release.version);
        case AndroidUpdateAction.download:
          await download(language: language);
        case AndroidUpdateAction.later:
        case null:
          break;
      }
    } catch (_) {
      updateStatus = UpdateStatusKind.failed;
      _operationError = 'CHECK_FAILED';
    } finally {
      checking = false;
      _notify();
    }
  }

  Future<void> download({required String language}) async {
    if (_disposed || !canDownload) return;
    final package = latestRelease!.androidPackage!;
    _starting = true;
    _operationError = null;
    _notify();
    try {
      final currentVersion = await _versionLoader();
      if (_disposed) return;
      // Refusing notifications does not refuse the explicitly requested APK.
      try {
        await channel.invokeMethod<Object?>('requestNotifications');
      } on PlatformException {
        // The in-app progress and install action remain available.
      }
      if (_disposed) return;
      final value = await channel.invokeMethod<Object?>('startDownload', {
        'version': package.version,
        'url': package.url.toString(),
        'sha256': package.sha256,
        'size': package.size,
        'userAgent': 'Cypas-NSOAlbum/${currentVersion.split('+').first}',
        'language': language == 'en' ? 'en' : 'zh',
      });
      if (!_disposed) status = AndroidUpdateStatus.fromNative(value);
    } catch (error) {
      _operationError = _errorCode(error, 'DOWNLOAD_FAILED');
    } finally {
      _starting = false;
      _schedulePoll();
      _notify();
    }
  }

  Future<void> restore() async {
    if (_disposed || _restoring) return;
    _restoring = true;
    try {
      final value = await channel.invokeMethod<Object?>('status');
      if (!_disposed) {
        status = AndroidUpdateStatus.fromNative(value);
        if (_operationError == 'STATUS_FAILED' || status.error != null) {
          _operationError = null;
        }
      }
    } catch (_) {
      _operationError = 'STATUS_FAILED';
    } finally {
      _restoring = false;
      _schedulePoll();
      _notify();
    }
  }

  Future<void> install() async {
    if (_disposed || !canInstall) return;
    installing = true;
    _operationError = null;
    _notify();
    try {
      await channel.invokeMethod<Object?>('install');
    } catch (error) {
      _operationError = _errorCode(error, 'INSTALL_UNAVAILABLE');
    } finally {
      await restore();
      installing = false;
      _notify();
    }
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    if (!foreground) {
      _poll?.cancel();
      _poll = null;
    } else {
      unawaited(restore());
    }
  }

  void _schedulePoll() {
    if (_disposed || !_foreground || !status.busy) {
      _poll?.cancel();
      _poll = null;
      return;
    }
    _poll ??= Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(restore()),
    );
  }

  String message(String language) {
    final english = language == 'en';
    final error = _operationError ?? status.error;
    if (error != null) return androidUpdateErrorMessage(error, language);
    return switch (status.state) {
      AndroidUpdateState.downloading =>
        english
            ? 'Downloading update${_progressText()}'
            : '正在下载更新${_progressText()}',
      AndroidUpdateState.verifying =>
        english ? 'Verifying the downloaded package…' : '正在校验安装包…',
      AndroidUpdateState.ready =>
        english
            ? 'Version ${status.version ?? ''} is ready to install.'
            : '版本 ${status.version ?? ''} 已准备好安装。',
      AndroidUpdateState.failed => androidUpdateErrorMessage(
        'DOWNLOAD_FAILED',
        language,
      ),
      AndroidUpdateState.idle => switch (updateStatus) {
        UpdateStatusKind.latest =>
          english ? 'You are using the latest version.' : '已是最新版本',
        UpdateStatusKind.available =>
          latestRelease?.androidPackage == null
              ? (english
                    ? 'Version ${latestRelease?.version ?? ''} is available. No verified Android package is available yet.'
                    : '发现新版本 ${latestRelease?.version ?? ''}，暂时没有可验证的 Android 安装包。')
              : (english
                    ? 'Version ${latestRelease?.version ?? ''} is available.'
                    : '发现新版本 ${latestRelease?.version ?? ''}。'),
        _ => '',
      },
    };
  }

  String _progressText() => status.total > 0
      ? ' (${(100 * status.received / status.total).clamp(0, 100).floor()}%)'
      : '';

  String _errorCode(Object error, String fallback) =>
      error is PlatformException ? error.code : fallback;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    unawaited(_service.close());
    super.dispose();
  }
}

String androidUpdateErrorMessage(String code, String language) {
  final english = language == 'en';
  return switch (code) {
    'CHECK_FAILED' =>
      english
          ? 'Unable to check for updates. Try again later.'
          : '检查更新失败，请稍后重试。',
    'INSTALL_PERMISSION_REQUIRED' =>
      english
          ? 'Allow installation from this app in system settings, then tap Install new version again.'
          : '请在系统设置中允许此应用安装软件，然后再次点击“安装新版本”。',
    'SIGNATURE_MISMATCH' =>
      english
          ? 'The update signature does not match this installation. Your existing app and data have not changed.'
          : '更新包签名与当前应用不一致。现有应用和数据未更改。',
    'HASH_MISMATCH' ||
    'INVALID_APK' ||
    'INVALID_UPDATE' ||
    'PACKAGE_MISMATCH' ||
    'VERSION_MISMATCH' ||
    'VERSION_NOT_NEWER' =>
      english
          ? 'The update package could not be verified. Check for updates and download it again.'
          : '更新安装包校验失败，请重新检查更新并下载。',
    'DOWNLOAD_TOO_LARGE' =>
      english
          ? 'The update package exceeds the download size limit.'
          : '更新安装包超出下载大小限制。',
    'STORAGE_UNAVAILABLE' =>
      english
          ? 'Update storage is unavailable. Check free space and try again.'
          : '更新存储不可用，请检查可用空间后重试。',
    'INSTALL_UNAVAILABLE' =>
      english
          ? 'Unable to open the system installer. Try again later.'
          : '无法打开系统安装器，请稍后重试。',
    'STATUS_FAILED' =>
      english
          ? 'Unable to read update progress. Reopen the app and try again.'
          : '无法读取更新进度，请重新打开应用后再试。',
    _ =>
      english
          ? 'The update download failed. Check for updates and try again.'
          : '更新下载失败，请重新检查更新后再试。',
  };
}
