import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../rust/bridge.dart' as rust_api;
import '../rust/models.dart';
import '../rust/nso/provider.dart';
import '../rust/settings.dart';
import 'app_backend.dart';
import 'account_name_history.dart';
import 'account_tool_requests.dart';
import 'account_tool_lifecycle.dart';
import 'nintendo_account_tools_backend.dart';
import 'app_logger.dart';
import 'storage_paths.dart';
import '../fonts/custom_font_store.dart';
import 'rust_initialization.dart';
import 'video_operation_progress.dart';
import 'mobile_storage_policy.dart';
import 'sync_failure_status.dart';
import 'device_sync/account_gate.dart';
import 'device_sync/account_storage.dart';
import 'device_sync/account_coordinator.dart';
import 'device_sync/startup_lifecycle.dart';
import '../platform/sync_notifications.dart';

const _windowsPicturesKnownFolderId = '{33E28130-4E1E-4676-835A-98395C3BC3BB}';

String interfaceLanguageForLocale(Locale locale) =>
    locale.languageCode.toLowerCase() == 'zh' ? 'zh' : 'en';

class RustBackend
    implements
        AppBackend,
        SyncScheduleBackend,
        SyncHistoryBackend,
        SyncNotificationBackend,
        AccountSyncBackend,
        OperationProgressBackend,
        MobileStorageBackend,
        NintendoAccountToolsBackend,
        NintendoGameImageBackend,
        NintendoAccountToolLifecycleBackend,
        AccountWorkBackend,
        AccountScheduleAdmissionBackend,
        NintendoAccountNameHistoryBackend,
        DeviceSyncStartupBackend {
  RustBackend._(
    this._storage,
    this._logger,
    this._libraryRoot,
    this._isolated,
  ) {
    deviceSyncStartup = DeviceSyncStartupLifecycle(
      gate: accountWorkGate,
      openLibrary: () async =>
          (await rust_api.deviceSyncOpenLibrary(libraryRoot: _libraryRoot))
              .handle,
      coordinator: (handle) => DeviceAccountCoordinator(
        library: handle,
        storage: FlutterAccountSecureStorage(_storage),
        gate: accountWorkGate,
        invalidate: invalidateDeviceAccounts,
        publish: publishDeviceAccounts,
      ),
      initialize: _initializeSettings,
      isolated: _isolated,
      onDiagnostic: (stage, error) =>
          _logger.error('[device_sync] stage=$stage', error),
    );
  }

  static final _prepared = <String, Future<RustBackend>>{};
  static const _sessionTokenKey = 'nintendo.session_token';
  static const _accountTokensKey = 'nintendo.account_tokens.v1';
  static const _accountProfilesKey = 'nintendo.account_profiles.v1';
  static const _selectedAccountKey = 'nintendo.selected_account.v1';
  static String _friendCodeKey(String accountId) =>
      'nintendo.friend_code.v1.$accountId';
  final FlutterSecureStorage _storage;
  @override
  final accountWorkGate = AccountWorkGate();
  final AppLogger _logger;
  final String _libraryRoot;
  final bool _isolated;
  @override
  late final DeviceSyncStartupLifecycle deviceSyncStartup;
  bool _initializingSettings = false;
  Future<AppSettings>? _defaults;
  Future<RustBackend>? _registration;

  LoginChallenge? _pendingLogin;
  int _accountCredentialEpoch = 0;
  int _accountMutationIntent = 0;
  int _loginFlow = 0;
  int _pendingLoginFlow = 0;
  int _pendingLoginIntent = 0;
  Future<void> _accountCommitTail = Future<void>.value();
  final Object _accountCommitZone = Object();
  Object? _accountCommitOwner;
  final _deviceInvalidatingAccounts = <String>{};

  Future<T> _commitAccounts<T>(Future<T> Function() action) {
    final inherited = Zone.current[_accountCommitZone];
    if (inherited != null && identical(inherited, _accountCommitOwner)) {
      return action();
    }
    final previous = _accountCommitTail;
    final done = Completer<void>();
    _accountCommitTail = done.future;
    return () async {
      await previous;
      final owner = Object();
      _accountCommitOwner = owner;
      try {
        return await runZoned(action, zoneValues: {_accountCommitZone: owner});
      } finally {
        _accountCommitOwner = null;
        done.complete();
      }
    }();
  }

  void _checkLogin(LoginChallenge pending, int flow, int intent, int epoch) {
    if (!identical(_pendingLogin, pending) ||
        flow != _loginFlow ||
        intent != _accountMutationIntent ||
        epoch != _accountCredentialEpoch) {
      throw StateError('Nintendo sign-in flow is no longer current');
    }
  }

  final _accountToolRequests = AccountToolRequests();
  final _syncNotifications = SyncNotifications(
    platform: Platform.operatingSystem,
  );
  @override
  final accountToolLifecycle = AccountToolLifecycle();
  AppSettings? _settings;
  int _syncCancellationEpoch = 0;
  final _operations = StreamController<OperationProgressValue>.broadcast();
  @override
  Stream<OperationProgressValue> get operationProgress => _operations.stream;

  @override
  Future<void> notifyAutomaticSyncCompleted({
    required int downloaded,
    required int existing,
    required int failed,
    required int accountCount,
    int failedAccountCount = 0,
  }) async {
    await _syncNotifications.show(
      language: settings.language,
      downloaded: downloaded,
      existing: existing,
      failed: failed,
      accountCount: accountCount,
      failedAccountCount: failedAccountCount,
    );
  }

  @override
  Future<List<MobileStorageLocation>> mobileStorageLocations() async {
    if (!Platform.isAndroid) return const [];
    final values = await const MethodChannel('io.github.cypas.nsoalbum/storage')
        .invokeListMethod<Object?>('locations');
    return [
      for (final item in values ?? const [])
        if (item is Map)
          MobileStorageLocation(
            id: item['id'] as String,
            path: item['path'] as String,
            removable: item['removable'] as bool,
          ),
    ];
  }

  Future<void> _ensureMobileStorageAvailable() async {
    if (!deviceSyncStartup.ready) throw const DeviceSyncBusy();
    if (!Platform.isAndroid) return;
    // Existing private legacy media paths remain valid. Removable locations
    // must still be mounted; never substitute another media root.
    final locations = await mobileStorageLocations();
    if (!mobileStorageIsAvailable(
      libraryPath: settings.libraryPath,
      applicationRoot: _libraryRoot,
      locations: locations,
    )) {
      throw StateError('Selected storage is unavailable');
    }
  }

  String? get _networkProxy => Platform.isAndroid ? null : settings.proxyUrl;

  static Future<RustBackend> open({
    FlutterSecureStorage? storage,
    AppLogger? logger,
    String? applicationRoot,
    bool isolated = false,
  }) async {
    final backend = await prepare(
      storage: storage,
      logger: logger,
      applicationRoot: applicationRoot,
      isolated: isolated,
    );
    await backend.deviceSyncStartup.start();
    if (!backend.deviceSyncStartup.ready) {
      throw AccountRecoveryRequired(
        backend.deviceSyncStartup.recovery?.status ?? 'startup_failed',
      );
    }
    return backend;
  }

  static Future<RustBackend> prepare({
    FlutterSecureStorage? storage,
    AppLogger? logger,
    String? applicationRoot,
    bool isolated = false,
  }) async {
    await ensureRustLibInitialized();
    if (isolated && applicationRoot == null) {
      throw ArgumentError('Isolated backend requires an explicit root');
    }
    final resolvedRoot =
        applicationRoot ??
        await resolveApplicationRoot(
          (await getApplicationSupportDirectory()).path,
        );
    final libraryRoot = await Directory(resolvedRoot).exists()
        ? await Directory(resolvedRoot).resolveSymbolicLinks()
        : resolvedRoot;
    final key = _rootKey(libraryRoot);
    final existing = _prepared[key];
    if (existing != null) {
      final backend = await existing;
      if (backend._isolated != isolated) {
        throw StateError('Library startup isolation does not match its owner');
      }
      return backend;
    }
    late final Future<RustBackend> preparing;
    preparing = () async {
      await rust_api.initCore(libraryRoot: libraryRoot);
      await rust_api.setRuntimeProxyPolicy(disableAppProxy: Platform.isAndroid);
      final appLogger =
          logger ?? AppLogger('$libraryRoot/logs/squid_album.log');
      await appLogger.ensureExists();
      final backend = RustBackend._(
        storage ?? const FlutterSecureStorage(),
        appLogger,
        libraryRoot,
        isolated,
      );
      backend._registration = preparing;
      try {
        backend._settings =
            await rust_api.bootstrapSettings() ??
            await backend._defaultSettings();
        await appLogger.info('Application core prepared');
        return backend;
      } catch (_) {
        await backend.deviceSyncStartup.close();
        rethrow;
      }
    }();
    _prepared[key] = preparing;
    try {
      return await preparing;
    } catch (_) {
      if (identical(_prepared[key], preparing)) _prepared.remove(key);
      rethrow;
    }
  }

  static String _rootKey(String root) {
    final path = p.normalize(p.absolute(root));
    return Platform.isWindows ? path.toLowerCase() : path;
  }

  @override
  Future<void> close() async {
    await deviceSyncStartup.close();
    final key = _rootKey(_libraryRoot);
    if (identical(_prepared[key], _registration)) _prepared.remove(key);
  }

  @override
  AppSettings get settings => _settings!;

  Future<void> invalidateDeviceAccounts(Set<String> accountIds) async {
    if (!accountWorkGate.busy) throw const DeviceSyncBusy();
    _accountCredentialEpoch++;
    _pendingLogin = null;
    _deviceInvalidatingAccounts.addAll(accountIds);
    final cleanup = accountToolLifecycle.invalidateAndWait(accountIds);
    try {
      for (final accountId in accountIds) {
        for (final id in _accountToolRequests.removeAccount(accountId)) {
          await rust_api.cancelAccountToolOperation(operationId: id);
        }
        await rust_api.clearAccountToolCache(accountId: accountId);
        await _storage.delete(key: _friendCodeKey(accountId));
      }
    } finally {
      await cleanup;
    }
    _deviceInvalidatingAccounts.removeAll(accountIds);
  }

  void publishDeviceAccounts(Set<String> accountIds) {
    if (!accountWorkGate.busy ||
        accountIds.any(_deviceInvalidatingAccounts.contains)) {
      throw const DeviceSyncBusy();
    }
    for (final accountId in accountIds) {
      accountToolLifecycle.accountAvailable(accountId);
    }
  }

  @override
  Future<bool> automaticAccountHasLocalHistory(String accountId) async {
    final history = await rust_api.syncAccountHistory(accountId: accountId);
    return history.lastSuccessfulSyncAt != null ||
        history.lastNewMediaAt != null ||
        history.latestAttempt != null;
  }

  @override
  String get logFilePath => _logger.path;

  @override
  Future<void> logError(
    String message,
    Object error, [
    StackTrace? stackTrace,
  ]) => _logger.error(message, error, stackTrace);

  @override
  Future<void> openLogFile() async {
    await _logger.ensureExists();
    if (Platform.isWindows) {
      await Process.start('notepad.exe', [_logger.path]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', [_logger.path]);
      return;
    }
    if (Platform.isLinux) {
      await Process.start('xdg-open', [_logger.path]);
      return;
    }
    final opened = await launchUrl(
      Uri.file(_logger.path),
      mode: LaunchMode.externalApplication,
    );
    if (!opened) throw StateError('Unable to open log file');
  }

  @override
  Future<void> openDirectory(String path) async {
    final directory = Directory(path.trim());
    if (!await directory.exists()) {
      throw StateError('Directory does not exist: ${directory.path}');
    }
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [
        directory.path,
      ], mode: ProcessStartMode.detached);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', [
        directory.path,
      ], mode: ProcessStartMode.detached);
      return;
    }
    if (Platform.isLinux) {
      await Process.start('xdg-open', [
        directory.path,
      ], mode: ProcessStartMode.detached);
      return;
    }
    final opened = await launchUrl(
      Uri.directory(directory.path),
      mode: LaunchMode.externalApplication,
    );
    if (!opened) throw StateError('Unable to open directory');
  }

  Future<AppSettings> loadSettings() async {
    if (!_initializingSettings && !deviceSyncStartup.ready) {
      throw const DeviceSyncBusy();
    }
    final persisted = await rust_api.loadSettings();
    if (persisted != null) {
      _settings = persisted;
      return persisted;
    }
    final defaults = await _defaultSettings();
    await rust_api.saveSettings(settings: defaults);
    _settings = defaults;
    return _settings!;
  }

  Future<void> _initializeSettings() async {
    _initializingSettings = true;
    try {
      await loadSettings();
    } finally {
      _initializingSettings = false;
    }
  }

  Future<AppSettings> _defaultSettings() =>
      _defaults ??= _buildDefaultSettings();

  Future<AppSettings> _buildDefaultSettings() async => AppSettings(
    libraryPath: _isolated
        ? '$_libraryRoot${Platform.pathSeparator}media'
        : await resolveDefaultLibraryPath(_libraryRoot),
    theme: 'ocean',
    language: interfaceLanguageForLocale(PlatformDispatcher.instance.locale),
    galleryColumns: Platform.isAndroid ? 2 : 4,
    galleryRows: 3,
    showNotePreview: true,
    showGameTag: true,
    compactTagDisplay: true,
    autoPlayVideo: false,
    autoSyncOnLaunch: true,
    notifyOnAutoSync: true,
    showSplatoonSchedule: true,
    showSplatoonFriendActivity: false,
    closeBehavior: 'ask',
    customFontPaths: const [],
    syncPolicy: const SyncPolicy(
      enabled: false,
      activeIntervalMinutes: 30,
      sleepAfterHours: 24,
    ),
  );

  @override
  Future<void> saveSettings(AppSettings value) async {
    if (!deviceSyncStartup.ready) throw const DeviceSyncBusy();
    final previousProxy = _settings?.proxyUrl;
    await rust_api.saveSettings(settings: value);
    _settings = value;
    if (previousProxy != value.proxyUrl) {
      accountToolLifecycle.networkChanged();
    }
  }

  @override
  Future<List<String>> importCustomFonts(List<String> sourcePaths) async {
    if (!deviceSyncStartup.ready) throw const DeviceSyncBusy();
    return CustomFontStore(supportDirectory: _libraryRoot)
        .importFiles(sourcePaths);
  }

  @override
  Future<List<MediaAsset>> listMedia({
    GalleryKindFilter kind = GalleryKindFilter.all,
    int limit = 100,
    int offset = 0,
    bool favoriteOnly = false,
    int? albumId,
    bool newestFirst = true,
    List<String> gameNames = const [],
    DateTime? importedFrom,
    DateTime? importedUntil,
    DateTime? capturedFrom,
    DateTime? capturedUntil,
    CapturedOnThisDay? capturedOnThisDay,
  }) => rust_api.listMedia(
    query: GalleryQuery(
      kind: kind,
      limit: limit,
      offset: offset,
      favoriteOnly: favoriteOnly,
      albumId: albumId,
      newestFirst: newestFirst,
      gameNames: gameNames,
      importedFrom: importedFrom,
      importedUntil: importedUntil,
      capturedFrom: capturedFrom,
      capturedUntil: capturedUntil,
      capturedOnThisDay: capturedOnThisDay,
    ),
  );

  @override
  Future<GalleryPage> listMediaPage(GalleryPageRequest request) =>
      rust_api.listMediaPage(request: request);

  @override
  Future<List<GameMediaCount>> listGameMediaCounts({int? albumId}) =>
      rust_api.listGameMediaCounts(albumId: albumId);

  @override
  Future<MediaDetails> loadMediaDetails(int mediaId) =>
      rust_api.mediaDetails(mediaId: mediaId);

  @override
  Future<List<AlbumSummary>> listAlbums() => rust_api.listAlbums();

  @override
  Future<int> createAlbum(
    String name, {
    required String description,
    required bool smart,
  }) =>
      rust_api.createAlbum(name: name, description: description, smart: smart);

  @override
  Future<void> updateAlbum(
    int albumId,
    String name, {
    required String description,
    required bool smart,
  }) => rust_api.updateAlbum(
    albumId: albumId,
    name: name,
    description: description,
    smart: smart,
  );

  @override
  Future<List<AlbumRule>> listAlbumRules(int albumId) =>
      rust_api.listAlbumRules(albumId: albumId);

  @override
  Future<void> replaceAlbumRules(int albumId, List<AlbumRule> rules) =>
      rust_api.replaceAlbumRules(albumId: albumId, rules: rules);

  @override
  Future<void> deleteAlbum(int albumId) =>
      rust_api.deleteAlbum(albumId: albumId);

  @override
  Future<void> addMediaToAlbum(int albumId, int mediaId) =>
      rust_api.addMediaToAlbum(albumId: albumId, mediaId: mediaId);

  @override
  Future<MediaDeletionResult> deleteMedia(int mediaId) =>
      rust_api.deleteMedia(mediaId: mediaId);

  @override
  Future<MediaDeletionResult> removeMediaFromAlbum(int albumId, int mediaId) =>
      rust_api.removeMediaFromAlbum(albumId: albumId, mediaId: mediaId);

  @override
  Future<LibraryRelocationResult> relocateMediaLibrary(
    AppSettings settings,
  ) async {
    await _ensureMobileStorageAvailable();
    final result = await rust_api.relocateMediaLibrary(settings: settings);
    _settings = settings;
    return result;
  }

  @override
  Future<ImportSummary> importLocalFiles(List<String> paths) async {
    await _ensureMobileStorageAvailable();
    return rust_api.importLocalFiles(paths: paths);
  }

  @override
  Future<ImportSummary> importCustomFiles(
    List<String> paths,
    String gameName,
  ) async {
    await _ensureMobileStorageAvailable();
    final id = 'import-${DateTime.now().microsecondsSinceEpoch}';
    var reading = false;
    Future<void> refresh() async {
      if (reading) return;
      reading = true;
      try {
        final progress = await rust_api.currentImportProgress(operationId: id);
        if (progress != null) {
          _operations.add(
            OperationProgressValue(
              operationId: id,
              kind: progress.kind,
              phase: progress.phase,
              status: progress.status,
              processed: progress.processedItems.toInt(),
              total: progress.totalItems?.toInt(),
              processedBytes: progress.processedBytes?.toInt(),
              totalBytes: progress.totalBytes?.toInt(),
            ),
          );
        }
      } catch (_) {
        // Progress polling must not interrupt the actual import.
      } finally {
        reading = false;
      }
    }

    _operations.add(
      OperationProgressValue(
        operationId: id,
        kind: 'custom_import',
        phase: 'discovering',
      ),
    );
    final timer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => unawaited(refresh()),
    );
    try {
      return await rust_api.importCustomFilesWithProgress(
        paths: paths,
        gameName: gameName,
        operationId: id,
      );
    } finally {
      timer.cancel();
      await refresh();
    }
  }

  @override
  Future<ImportSummary> importMtpFiles(
    List<String> paths,
    String deviceName,
  ) async {
    await _ensureMobileStorageAvailable();
    return rust_api.importMtpFiles(paths: paths, deviceName: deviceName);
  }

  @override
  Future<MediaExportSummary> exportMedia(
    List<int> mediaIds,
    String destination,
    String nameFormat,
  ) => rust_api.exportMedia(
    mediaIds: Int64List.fromList(mediaIds),
    destination: destination,
    nameFormat: nameFormat,
  );

  @override
  Future<MediaAsset> trimVideo(
    MediaAsset source,
    Duration start,
    Duration end, {
    required bool overwrite,
  }) async {
    if (source.kind != MediaKind.video ||
        start.isNegative ||
        end <= start ||
        end - start < const Duration(milliseconds: 300)) {
      throw ArgumentError('Invalid video trim range');
    }
    await _ensureMobileStorageAvailable();
    final operation = VideoOperationProgress(
      operationId: 'trim-${DateTime.now().microsecondsSinceEpoch}',
      kind: 'video_trim',
      duration: end - start,
    );
    _operations.add(operation.encode(0));
    final output = await _newVideoProcessingPath('trim', 'mp4');
    try {
      await _runFfmpeg([
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-ss',
        _ffmpegTime(start),
        '-i',
        source.storagePath,
        '-t',
        _ffmpegTime(end - start),
        '-map',
        '0:v:0',
        '-map',
        '0:a:0?',
        '-c:v',
        'mpeg4',
        '-q:v',
        '2',
        '-c:a',
        'aac',
        '-b:a',
        '160k',
        '-movflags',
        '+faststart',
        output,
      ], operation);
      _operations.add(operation.ingesting());
      final result = await rust_api.commitVideoEdit(
        mediaId: source.id,
        processedPath: output,
        overwrite: overwrite,
      );
      _operations.add(operation.complete());
      return result;
    } catch (_) {
      _operations.add(operation.failed());
      rethrow;
    } finally {
      await discardTemporaryMedia(output);
    }
  }

  @override
  Future<MediaAsset> saveVideoFrame(
    MediaAsset source,
    Uint8List bytes,
    String extension,
  ) async {
    await _ensureMobileStorageAvailable();
    return rust_api.saveVideoFrame(
      mediaId: source.id,
      bytes: bytes,
      extension_: extension,
    );
  }

  @override
  Future<String> createMergedVideoPreview(List<MediaAsset> videos) async {
    final sources = videos
        .where((item) => item.kind == MediaKind.video)
        .toList();
    if (sources.length < 2) {
      throw ArgumentError('At least two videos are required');
    }
    await _ensureMobileStorageAvailable();
    Duration? expected;
    var milliseconds = 0;
    var known = true;
    for (final source in sources) {
      double? seconds;
      try {
        final info = await FFprobeKit.getMediaInformation(source.storagePath);
        seconds = double.tryParse(
          info.getMediaInformation()?.getDuration() ?? '',
        );
      } catch (_) {
        // Metadata is optional; encoding can report an indeterminate stage.
      }
      if (seconds == null || !seconds.isFinite || seconds <= 0) {
        known = false;
      } else {
        milliseconds += (seconds * 1000).round();
      }
    }
    if (known) expected = Duration(milliseconds: milliseconds);
    final operation = VideoOperationProgress(
      operationId: 'merge-preview-${DateTime.now().microsecondsSinceEpoch}',
      kind: 'video_merge_preview',
      duration: expected,
    );
    final output = await _newVideoProcessingPath('merge', 'mp4');
    final arguments = <String>['-hide_banner', '-loglevel', 'error', '-y'];
    for (final source in sources) {
      arguments.addAll(['-i', source.storagePath]);
    }
    final filters = <String>[];
    final concatInputs = StringBuffer();
    for (var index = 0; index < sources.length; index += 1) {
      filters.add(
        '[$index:v:0]scale=1280:720:force_original_aspect_ratio=decrease,'
        'pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,'
        'setpts=PTS-STARTPTS[v$index]',
      );
      filters.add('[$index:a:0]aresample=48000,asetpts=PTS-STARTPTS[a$index]');
      concatInputs.write('[v$index][a$index]');
    }
    filters.add('$concatInputs concat=n=${sources.length}:v=1:a=1[vout][aout]');
    arguments.addAll([
      '-filter_complex',
      filters.join(';'),
      '-map',
      '[vout]',
      '-map',
      '[aout]',
      '-c:v',
      'mpeg4',
      '-q:v',
      '3',
      '-c:a',
      'aac',
      '-b:a',
      '160k',
      '-movflags',
      '+faststart',
      output,
    ]);
    try {
      await _runFfmpeg(arguments, operation);
      _operations.add(operation.complete());
      return output;
    } catch (_) {
      _operations.add(operation.failed());
      await discardTemporaryMedia(output);
      rethrow;
    }
  }

  @override
  Future<MediaAsset> saveMergedVideo(
    List<MediaAsset> videos, {
    String? preparedPath,
  }) async {
    await _ensureMobileStorageAvailable();
    final sources = videos
        .where((item) => item.kind == MediaKind.video)
        .toList();
    final output = preparedPath ?? await createMergedVideoPreview(sources);
    final operation = VideoOperationProgress(
      operationId: 'merge-save-${DateTime.now().microsecondsSinceEpoch}',
      kind: 'video_merge',
    );
    try {
      _operations.add(operation.ingesting());
      final result = await rust_api.commitMergedVideo(
        mediaIds: Int64List.fromList(sources.map((item) => item.id).toList()),
        processedPath: output,
      );
      _operations.add(operation.complete());
      return result;
    } catch (_) {
      _operations.add(operation.failed());
      rethrow;
    } finally {
      await discardTemporaryMedia(output);
    }
  }

  @override
  Future<void> discardTemporaryMedia(String path) async {
    final root = (await _videoProcessingDirectory()).absolute.path;
    final candidate = File(path).absolute.path;
    final normalizedRoot = Platform.isWindows ? root.toLowerCase() : root;
    final normalizedCandidate = Platform.isWindows
        ? candidate.toLowerCase()
        : candidate;
    if (!normalizedCandidate.startsWith(
      '$normalizedRoot${Platform.pathSeparator}',
    )) {
      return;
    }
    final file = File(candidate);
    if (await file.exists()) await file.delete();
  }

  Future<String> _newVideoProcessingPath(
    String prefix,
    String extension,
  ) async {
    final root = await _videoProcessingDirectory();
    await root.create(recursive: true);
    return '${root.path}${Platform.pathSeparator}$prefix-${DateTime.now().microsecondsSinceEpoch}.$extension';
  }

  Future<Directory> _videoProcessingDirectory() async => Directory(
    _isolated
        ? '$_libraryRoot${Platform.pathSeparator}video_processing'
        : '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}squid_album_video_processing',
  );

  Future<void> _runFfmpeg(
    List<String> arguments,
    VideoOperationProgress operation,
  ) async {
    final completion = Completer<void>();
    var running = true;
    _operations.add(operation.encode(0));
    final session = await FFmpegKit.executeWithArgumentsAsync(
      arguments,
      (_) {
        running = false;
        if (!completion.isCompleted) completion.complete();
      },
      null,
      (statistics) {
        if (running) _operations.add(operation.encode(statistics.getTime()));
      },
    );
    await completion.future;
    final returnCode = await session.getReturnCode();
    if (ReturnCode.isSuccess(returnCode)) return;
    final output = (await session.getOutput())?.trim();
    final readable = output == null || output.isEmpty
        ? 'FFmpeg exited with code ${returnCode?.getValue() ?? 'unknown'}'
        : output.length > 3000
        ? output.substring(output.length - 3000)
        : output;
    throw StateError(readable);
  }

  String _ffmpegTime(Duration value) =>
      (value.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(
        6,
      );

  @override
  Future<void> setFavorite(int mediaId, bool favorite) =>
      rust_api.setFavorite(mediaId: mediaId, favorite: favorite);

  @override
  Future<List<String>> listTags() => rust_api.listTags();

  @override
  Future<List<GameTagSummary>> listGameTags() => rust_api.listGameTags();

  @override
  Future<List<GameTagAliasSummary>> listGameTagAliases() =>
      rust_api.listGameTagAliases();

  @override
  Future<void> recordGameTagSelection(String gameName) =>
      rust_api.recordGameTagSelection(gameName: gameName);

  @override
  Future<void> setNote(int mediaId, String note) =>
      rust_api.setNote(mediaId: mediaId, note: note);

  @override
  Future<void> replaceTags(int mediaId, List<String> tags) =>
      rust_api.replaceTags(mediaId: mediaId, tags: tags);

  @override
  Future<List<TagUsageSummary>> listTagUsage() => rust_api.listTagUsage();

  @override
  Future<int> createTag(String name) => rust_api.createTag(name: name);

  @override
  Future<void> renameTag(int tagId, String newName) =>
      rust_api.renameTag(tagId: tagId, newName: newName);

  @override
  Future<void> deleteTag(int tagId) => rust_api.deleteTag(tagId: tagId);

  @override
  Future<void> mergeTags(List<int> tagIds, String targetName) => rust_api
      .mergeTags(tagIds: Int64List.fromList(tagIds), targetName: targetName);

  @override
  Future<void> mergeGameTags(List<String> gameNames, String targetName) =>
      rust_api.mergeGameTags(gameNames: gameNames, targetName: targetName);

  @override
  Future<void> renameGameTag(String gameName, String targetName) =>
      rust_api.renameGameTag(gameName: gameName, targetName: targetName);

  Future<LoginChallenge> _beginNintendoLogin({bool openBrowser = true}) async {
    _requireAccountAccess();
    final flow = ++_loginFlow;
    final intent = ++_accountMutationIntent;
    _pendingLogin = null;
    final challenge = await rust_api.createNintendoLoginChallenge(
      proxyUrl: _networkProxy,
    );
    if (flow != _loginFlow || intent != _accountMutationIntent) {
      throw StateError('Nintendo sign-in flow is no longer current');
    }
    if (openBrowser) {
      final opened = await launchUrl(
        Uri.parse(challenge.authorizationUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        throw StateError(
          settings.language == 'en'
              ? 'Unable to open the Nintendo Account sign-in page'
              : '无法打开 Nintendo Account 登录页',
        );
      }
    }
    if (flow != _loginFlow || intent != _accountMutationIntent) {
      throw StateError('Nintendo sign-in flow is no longer current');
    }
    _pendingLogin = challenge;
    _pendingLoginFlow = flow;
    _pendingLoginIntent = intent;
    return challenge;
  }

  @override
  Future<void> beginNintendoLogin() =>
      accountWorkGate.normal(() => _beginNintendoLogin());

  @override
  Future<void> completeNintendoLogin(String callbackUrl) =>
      accountWorkGate.normal(() => _completeNintendoLogin(callbackUrl));

  Future<void> _completeNintendoLogin(String callbackUrl) async {
    _requireAccountAccess();
    final pending = _pendingLogin;
    if (pending == null) {
      throw StateError(
        settings.language == 'en'
            ? 'There is no pending Nintendo sign-in flow'
            : '没有待完成的 Nintendo 登录流程',
      );
    }
    final flow = _pendingLoginFlow;
    final intent = _pendingLoginIntent;
    final epoch = _accountCredentialEpoch;
    _checkLogin(pending, flow, intent, epoch);
    final sessionToken = await rust_api.exchangeNintendoCallback(
      callbackUrl: callbackUrl,
      expectedState: pending.state,
      verifier: pending.verifier,
      proxyUrl: _networkProxy,
    );
    _checkLogin(pending, flow, intent, epoch);
    final session = await rust_api.establishCoralSession(
      sessionToken: sessionToken,
      proxyUrl: _networkProxy,
    );
    _checkLogin(pending, flow, intent, epoch);
    final accountId = _accountId(session);
    await _commitAccounts(() async {
      _checkLogin(pending, flow, intent, epoch);
      final tokens = await _readStoredAccountTokens();
      tokens[accountId] = sessionToken;
      final profileJson = await _sessionProfileJson(accountId, session);
      await _validateAccountCandidate(tokens, accountId, profileJson);
      _checkLogin(pending, flow, intent, epoch);
      final publishingEpoch = ++_accountCredentialEpoch;
      final cleanup = accountToolLifecycle.invalidateAndWait({accountId});
      for (final id in _accountToolRequests.removeAccount(accountId)) {
        await rust_api.cancelAccountToolOperation(operationId: id);
      }
      await rust_api.clearAccountToolCache(accountId: accountId);
      await cleanup;
      await _storage.delete(key: _friendCodeKey(accountId));
      _checkLogin(pending, flow, intent, publishingEpoch);
      // Once the first OS mutation is admitted, finish this one serialized
      // commit. A newer mutation runs afterward, never between its four keys.
      await _writeAccountTokens(tokens);
      await _storage.write(key: _selectedAccountKey, value: accountId);
      await _storage.delete(key: _sessionTokenKey);
      await _writeProfileJson(profileJson);
      accountToolLifecycle.accountAvailable(accountId);
      if (identical(_pendingLogin, pending) && _pendingLoginFlow == flow) {
        _pendingLogin = null;
      }
    });
  }

  @override
  Future<bool> get isSignedIn => deviceSyncStartup.deferred
      ? Future.value(false)
      : accountWorkGate.normal(_isSignedIn);
  Future<bool> _isSignedIn() async {
    if (_isolated) return false;
    if ((await _readStoredAccountTokens()).isNotEmpty) return true;
    return (await _storage.read(key: _sessionTokenKey))?.isNotEmpty == true;
  }

  @override
  Future<NintendoAccountProfile?> get nintendoAccountProfile =>
      deviceSyncStartup.deferred
      ? Future.value(null)
      : accountWorkGate.normal(_nintendoAccountProfile);
  Future<NintendoAccountProfile?> _nintendoAccountProfile() async {
    final accountId = await selectedNintendoAccountId;
    if (accountId == null) return null;
    return (await _readCachedProfiles())[accountId];
  }

  @override
  Future<List<NintendoAccountProfile>> listNintendoAccounts() =>
      deviceSyncStartup.deferred
      ? Future.value(const [])
      : accountWorkGate.normal(_listNintendoAccounts);
  Future<List<NintendoAccountProfile>> _listNintendoAccounts() async {
    if (_isolated) return const [];
    final tokens = await _readAccountTokens();
    final selected = await selectedNintendoAccountId;
    final accountIds = tokens.keys.toList(growable: false)
      ..sort((left, right) {
        if (left == selected) return -1;
        if (right == selected) return 1;
        return left.compareTo(right);
      });
    final cached = await _readCachedProfiles();
    return accountIds
        .map(
          (accountId) =>
              cached[accountId] ??
              NintendoAccountProfile(
                accountId: accountId,
                nickname: settings.language == 'en'
                    ? 'Nintendo Account'
                    : 'Nintendo 账号',
              ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<NintendoAccountNameRecord>> listNintendoAccountNameHistory() =>
      accountWorkGate.normal(() async {
        _requireAccountAccess();
        if (_isolated) return const [];
        return accountNamesFromProfiles(await _readRawProfiles()).values
            .toList(growable: false);
      });

  @override
  Future<String?> get selectedNintendoAccountId => deviceSyncStartup.deferred
      ? Future.value(null)
      : accountWorkGate.normal(_selectedNintendoAccountId);
  Future<String?> _selectedNintendoAccountId() async {
    if (_isolated) return null;
    final tokens = await _readAccountTokens();
    if (tokens.isEmpty) return null;
    final selected = await _storage.read(key: _selectedAccountKey);
    if (selected != null && tokens.containsKey(selected)) return selected;
    return _commitAccounts(() async {
      final current = await _readStoredAccountTokens();
      if (current.isEmpty) return null;
      final latest = await _storage.read(key: _selectedAccountKey);
      if (latest != null && current.containsKey(latest)) return latest;
      final fallback = current.keys.first;
      await _storage.write(key: _selectedAccountKey, value: fallback);
      return fallback;
    });
  }

  @override
  Future<void> selectNintendoAccount(String accountId) =>
      accountWorkGate.normal(() => _selectNintendoAccount(accountId));
  Future<void> _selectNintendoAccount(String accountId) async {
    _requireAccountAccess();
    _accountMutationIntent++;
    await _commitAccounts(() async {
      final tokens = await _readStoredAccountTokens();
      if (!tokens.containsKey(accountId)) {
        throw StateError('Nintendo account is no longer available');
      }
      await _storage.write(key: _selectedAccountKey, value: accountId);
    });
  }

  @override
  Future<void> removeNintendoAccount(String accountId) =>
      accountWorkGate.normal(() => _removeNintendoAccount(accountId));
  Future<void> _removeNintendoAccount(String accountId) async {
    _requireAccountAccess();
    _accountMutationIntent++;
    _pendingLogin = null;
    await _commitAccounts(() async {
      _accountCredentialEpoch++;
      final cleanup = accountToolLifecycle.invalidateAndWait({accountId});
      for (final id in _accountToolRequests.removeAccount(accountId)) {
        await rust_api.cancelAccountToolOperation(operationId: id);
      }
      await rust_api.clearAccountToolCache(accountId: accountId);
      await cleanup;
      final tokens = await _readStoredAccountTokens();
      tokens.remove(accountId);
      await _storage.delete(key: _friendCodeKey(accountId));
      final profiles = await _readCachedProfiles();
      final previous = profiles[accountId];
      if (previous != null) {
        profiles[accountId] = NintendoAccountProfile(
          accountId: accountId,
          nickname: previous.nickname,
        );
      }
      await _writeCachedProfiles(profiles);
      await _writeAccountTokens(tokens);
      final selected = await _storage.read(key: _selectedAccountKey);
      if (selected == accountId || !tokens.containsKey(selected)) {
        if (tokens.isEmpty) {
          await _storage.delete(key: _selectedAccountKey);
        } else {
          await _storage.write(
            key: _selectedAccountKey,
            value: tokens.keys.first,
          );
        }
      }
    });
  }

  Future<T> _withAccountTool<T>(
    String accountId,
    String operationId,
    Future<T> Function(String sessionToken) action,
  ) => accountWorkGate.normal(
    () => _withAccountToolAdmitted(accountId, operationId, action),
  );

  Future<T> _withAccountToolAdmitted<T>(
    String accountId,
    String operationId,
    Future<T> Function(String sessionToken) action,
  ) async {
    _requireAccountAccess();
    if (accountToolLifecycle.isRemoved(accountId)) {
      throw StateError('account_tool_sign_in_required');
    }
    final request = _accountToolRequests.begin(accountId, operationId);
    try {
      final tokens = await _readAccountTokens();
      if (accountToolLifecycle.isRemoved(accountId) ||
          !_accountToolRequests.isCurrent(request)) {
        throw StateError('account_tool_cancelled');
      }
      final token = tokens[accountId];
      if (token == null || token.isEmpty) {
        throw StateError('account_tool_sign_in_required');
      }
      final result = await action(token);
      if (accountToolLifecycle.isRemoved(accountId) ||
          !_accountToolRequests.isCurrent(request)) {
        throw StateError('account_tool_cancelled');
      }
      return result;
    } finally {
      _accountToolRequests.finish(request);
    }
  }

  @override
  Future<NintendoFriendsSnapshot> loadNintendoFriends(
    String accountId,
    String operationId,
    {
    bool includeSplatoonActivity = false,
    }
  ) => _withAccountTool(
    accountId,
    operationId,
    (token) => rust_api.nintendoFriends(
      accountId: accountId,
      sessionToken: token,
      operationId: operationId,
      proxyUrl: _networkProxy,
      includeSplatoonFriendActivity: includeSplatoonActivity,
    ),
  );

  @override
  Future<Uint8List> loadNintendoFriendAvatar(
    String accountId,
    String friendId,
    String operationId,
  ) => _withAccountTool(
    accountId,
    operationId,
    (token) => rust_api.nintendoFriendAvatar(
      accountId: accountId,
      sessionToken: token,
      friendId: friendId,
      operationId: operationId,
      proxyUrl: _networkProxy,
    ),
  );

  @override
  Future<Uint8List> loadNintendoGameImage(
    String accountId,
    String gameName,
    String operationId,
  ) => _withAccountTool(
    accountId,
    operationId,
    (token) => rust_api.nintendoGameImage(
      accountId: accountId,
      sessionToken: token,
      gameName: gameName,
      operationId: operationId,
      proxyUrl: _networkProxy,
    ),
  );

  @override
  Future<List<NintendoFriendGame>> loadNintendoFriendPlayLog(
    String accountId,
    String friendId,
    String operationId,
  ) => _withAccountTool(
    accountId,
    operationId,
    (token) => rust_api.nintendoFriendPlayLog(
      accountId: accountId,
      sessionToken: token,
      friendId: friendId,
      operationId: operationId,
      proxyUrl: _networkProxy,
    ),
  );

  @override
  Future<NintendoFriendCodeSnapshot> loadNintendoFriendCode(
    String accountId,
    String operationId,
  ) => _withAccountTool(accountId, operationId, (token) async {
    final epoch = _accountCredentialEpoch;
    final stored = await _storage.read(key: _friendCodeKey(accountId));
    if (stored != null) {
      try {
        final value = jsonDecode(stored) as Map<String, dynamic>;
        final code = value['friendCode'] as String;
        if (RegExp(r'^[0-9]{4}-[0-9]{4}-[0-9]{4}$').hasMatch(code)) {
          return NintendoFriendCodeSnapshot(
            friendCode: code,
            url: value['url'] as String? ?? '',
          );
        }
      } catch (_) {
        // An incomplete cache is replaced only after a successful request.
      }
    }
    final result = await rust_api.nintendoFriendCode(
      accountId: accountId,
      sessionToken: token,
      operationId: operationId,
      proxyUrl: _networkProxy,
    );
    await _commitAccounts(() async {
      if (epoch != _accountCredentialEpoch ||
          accountToolLifecycle.isRemoved(accountId) ||
          (await _readStoredAccountTokens())[accountId] != token) {
        throw StateError('account_tool_cancelled');
      }
      await _storage.write(
        key: _friendCodeKey(accountId),
        value: jsonEncode({'friendCode': result.friendCode, 'url': result.url}),
      );
    });
    return result;
  });

  @override
  Future<NintendoFriendCodeUser> lookupNintendoFriendCode(
    String accountId,
    String friendCode,
    String operationId,
  ) => _withAccountTool(
    accountId,
    operationId,
    (token) => rust_api.nintendoFriendLookup(
      accountId: accountId,
      sessionToken: token,
      friendCode: friendCode,
      operationId: operationId,
      proxyUrl: _networkProxy,
    ),
  );

  @override
  Future<NintendoFriendRequestResult> sendNintendoFriendRequest(
    String accountId,
    String friendId,
    String operationId,
  ) => _withAccountTool(
    accountId,
    operationId,
    (token) => rust_api.nintendoSendFriendRequest(
      accountId: accountId,
      sessionToken: token,
      friendId: friendId,
      operationId: operationId,
      proxyUrl: _networkProxy,
    ),
  );

  @override
  Future<void> updateNintendoFriendNote(
    String accountId,
    String friendId,
    String note,
    String operationId,
  ) => _withAccountTool(
    accountId,
    operationId,
    (token) => rust_api.nintendoUpdateFriendNote(
      accountId: accountId,
      sessionToken: token,
      friendId: friendId,
      note: note,
      operationId: operationId,
      proxyUrl: _networkProxy,
    ),
  );

  @override
  Future<SplatNetWebSession> prepareSplatNetSession(
    String accountId,
    String operationId, {
    bool forceRefresh = false,
  }) => _withAccountTool(
    accountId,
    operationId,
    (token) => rust_api.prepareSplatnetSession(
      accountId: accountId,
      sessionToken: token,
      operationId: operationId,
      forceRefresh: forceRefresh,
      proxyUrl: _networkProxy,
    ),
  );

  @override
  Future<SeedExportPayload> prepareSeedExport(
    String accountId,
    String operationId,
  ) => _withAccountTool(
    accountId,
    operationId,
    (token) => rust_api.prepareSeedExport(
      accountId: accountId,
      sessionToken: token,
      operationId: operationId,
      proxyUrl: _networkProxy,
    ),
  );

  @override
  Future<void> cancelAccountToolOperation(String operationId) async {
    _accountToolRequests.cancel(operationId);
    await rust_api.cancelAccountToolOperation(operationId: operationId);
  }

  NintendoAccountProfile _profileFromSession(
    String accountId,
    CoralSession session,
  ) => NintendoAccountProfile(
    accountId: accountId,
    nickname: session.nickname,
    avatarUrl: session.avatarUrl,
    avatarBytes: session.avatarBytes,
  );

  Future<Map<String, String>> _readStoredAccountTokens() async {
    _requireAccountAccess();
    final raw = await _storage.read(key: _accountTokensKey);
    if (raw == null || raw.isEmpty) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return {};
    return decoded.map(
      (key, value) => MapEntry(key, value is String ? value : ''),
    )..removeWhere((_, value) => value.isEmpty);
  }

  Future<Map<String, String>> _readAccountTokens() async {
    _requireAccountAccess();
    final intent = _accountMutationIntent;
    final epoch = _accountCredentialEpoch;
    final tokens = await _readStoredAccountTokens();
    if (tokens.isNotEmpty) return tokens;
    final legacy = await _storage.read(key: _sessionTokenKey);
    if (legacy == null || legacy.isEmpty) return tokens;
    final session = await rust_api.establishCoralSession(
      sessionToken: legacy,
      proxyUrl: _networkProxy,
    );
    void checkMigration() {
      if (intent != _accountMutationIntent ||
          epoch != _accountCredentialEpoch) {
        throw StateError('Nintendo legacy account state changed');
      }
    }

    checkMigration();
    return _commitAccounts(() async {
      checkMigration();
      final current = await _readStoredAccountTokens();
      final currentLegacy = await _storage.read(key: _sessionTokenKey);
      checkMigration();
      if (current.isNotEmpty || currentLegacy != legacy) {
        throw StateError('Nintendo legacy account state changed');
      }
      final accountId = _accountId(session);
      final migrated = <String, String>{accountId: legacy};
      final profileJson = await _sessionProfileJson(accountId, session);
      await _validateAccountCandidate(migrated, accountId, profileJson);
      checkMigration();
      _accountCredentialEpoch++;
      await _writeProfileJson(profileJson);
      await _writeAccountTokens(migrated);
      await _storage.write(key: _selectedAccountKey, value: accountId);
      await _storage.delete(key: _sessionTokenKey);
      return migrated;
    });
  }

  Future<void> _writeAccountTokens(Map<String, String> tokens) async {
    _requireAccountAccess();
    final raw = await readRawAccountKeys(FlutterAccountSecureStorage(_storage));
    validateRawAccountSize({
      ...raw,
      _accountTokensKey: tokens.isEmpty ? null : jsonEncode(tokens),
    });
    if (tokens.isEmpty) {
      await _storage.delete(key: _accountTokensKey);
      return;
    }
    await _storage.write(key: _accountTokensKey, value: jsonEncode(tokens));
  }

  Future<Map<String, NintendoAccountProfile>> _readCachedProfiles() async {
    _requireAccountAccess();
    final raw = await _storage.read(key: _accountProfilesKey);
    if (raw == null || raw.isEmpty) return {};
    if (raw.length > maxAccountRawBytes ||
        utf8.encode(raw).length > maxAccountRawBytes) {
      throw AccountPayloadInvalid();
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return {};
    }
    if (decoded is! Map<String, dynamic>) return {};
    final profiles = <String, NintendoAccountProfile>{};
    for (final entry in decoded.entries) {
      final value = entry.value;
      if (value is! Map<String, dynamic>) continue;
      Uint8List? avatarBytes;
      final avatarBase64 = value['avatar_base64'];
      if (avatarBase64 is String && avatarBase64.isNotEmpty) {
        try {
          avatarBytes = Uint8List.fromList(base64Decode(avatarBase64));
        } catch (_) {
          avatarBytes = null;
        }
      }
      profiles[entry.key] = NintendoAccountProfile(
        accountId: entry.key,
        nickname: value['nickname'] is String
            ? value['nickname'] as String
            : 'Nintendo Account',
        avatarUrl: value['avatar_url'] is String
            ? value['avatar_url'] as String
            : null,
        avatarBytes: avatarBytes,
      );
    }
    return profiles;
  }

  Future<void> _writeCachedProfiles(
    Map<String, NintendoAccountProfile> profiles,
  ) async {
    _requireAccountAccess();
    await _writeProfileJson(await _encodeProfiles(profiles));
  }

  Future<Map<String, dynamic>> _readRawProfiles() async {
    final raw = await _storage.read(key: _accountProfilesKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // Do not leak malformed account metadata into a diagnostic.
    }
    throw AccountPayloadInvalid();
  }

  Future<String?> _encodeProfiles(
    Map<String, NintendoAccountProfile> profiles, {
    String? refreshedAccountId,
  }) async {
    if (profiles.isEmpty) return null;
    final old = await _readRawProfiles();
    final encoded = profiles.map(
      (accountId, profile) => MapEntry(accountId, {
        if (accountId == refreshedAccountId ||
            old[accountId] is! Map ||
            (old[accountId] as Map)['nickname'] is String)
          'nickname': profile.nickname,
        if (profile.avatarUrl != null) 'avatar_url': profile.avatarUrl,
        if (profile.avatarBytes != null)
          'avatar_base64': base64Encode(profile.avatarBytes!),
        if (accountId == refreshedAccountId)
          'name_updated_at': DateTime.now().toUtc().toIso8601String()
        else if (old[accountId] is Map &&
            (old[accountId] as Map)['name_updated_at'] is String)
          'name_updated_at': (old[accountId] as Map)['name_updated_at'],
      }),
    );
    return jsonEncode(encoded);
  }

  Future<String?> _sessionProfileJson(String id, CoralSession session) async {
    final profiles = await _readCachedProfiles();
    final previous = profiles[id];
    final profile = _profileFromSession(id, session);
    profiles[id] = session.nickname.trim().isEmpty && previous != null
        ? NintendoAccountProfile(
            accountId: id,
            nickname: previous.nickname,
            avatarUrl: profile.avatarUrl,
            avatarBytes: profile.avatarBytes,
          )
        : profile;
    return _encodeProfiles(
      profiles,
      refreshedAccountId: session.nickname.trim().isEmpty ? null : id,
    );
  }

  Future<void> _validateAccountCandidate(
    Map<String, String> tokens,
    String selected,
    String? profiles,
  ) async {
    final before = await readRawAccountKeys(
      FlutterAccountSecureStorage(_storage),
    );
    validateRawAccountSize({
      ...before,
      _sessionTokenKey: null,
      _accountTokensKey: jsonEncode(tokens),
      _selectedAccountKey: selected,
      _accountProfilesKey: profiles,
    });
  }

  Future<void> _writeProfileJson(String? encoded) async {
    final before = await readRawAccountKeys(
      FlutterAccountSecureStorage(_storage),
    );
    validateRawAccountSize({...before, _accountProfilesKey: encoded});
    if (encoded == null) {
      await _storage.delete(key: _accountProfilesKey);
    } else {
      await _storage.write(key: _accountProfilesKey, value: encoded);
    }
  }

  Future<void> _cacheProfile(
    String accountId,
    CoralSession session, {
    int? expectedEpoch,
    String? expectedToken,
  }) => _commitAccounts(() async {
    if ((expectedEpoch != null && expectedEpoch != _accountCredentialEpoch) ||
        (expectedToken != null &&
            (await _readStoredAccountTokens())[accountId] != expectedToken)) {
      throw StateError('Nintendo account profile is no longer current');
    }
    await _writeProfileJson(await _sessionProfileJson(accountId, session));
  });

  String _accountId(CoralSession session) {
    final value = session.naId ?? session.coralUserId;
    if (value == null || value.trim().isEmpty) {
      throw StateError('Nintendo session did not include an account ID');
    }
    return value.trim();
  }

  @override
  Future<SyncSummary> syncNintendoAlbum() =>
      accountWorkGate.normal(_syncNintendoAlbum);
  Future<SyncSummary> _syncNintendoAlbum() async {
    _requireAccountAccess();
    final epoch = _syncCancellationEpoch;
    final accountId = await selectedNintendoAccountId;
    if (accountId == null) {
      throw StateError(
        settings.language == 'en'
            ? 'Sign in to Nintendo Account first'
            : '请先登录 Nintendo Account',
      );
    }
    return _syncNintendoAccount(accountId, cancellationEpoch: epoch);
  }

  @override
  Future<SyncSummary> syncNintendoAccount(String accountId) =>
      accountWorkGate.normal(() => _syncNintendoAccount(accountId));
  Future<SyncSummary> _syncNintendoAccount(
    String accountId, {
    int? cancellationEpoch,
  }) async {
    _requireAccountAccess();
    final epoch = cancellationEpoch ?? _syncCancellationEpoch;
    var invalidated = accountToolLifecycle.isRemoved(accountId);
    final cleanup = accountToolLifecycle.registerCleanup(accountId, () async {
      invalidated = true;
    });
    void checkCancelled() {
      if (epoch != _syncCancellationEpoch || invalidated) {
        throw StateError('task cancelled');
      }
    }

    try {
      checkCancelled();
      await _ensureMobileStorageAvailable();
      checkCancelled();
      final tokens = await _readAccountTokens();
      checkCancelled();
      final token = tokens[accountId];
      if (token == null) throw StateError('Nintendo account requires sign-in');
      // Rust registers cancellation before any authentication/network work.
      final summary = await rust_api.syncNsoFromSessionTokenForAccount(
        sessionToken: token,
        expectedAccount: accountId,
        proxyUrl: _networkProxy,
      );
      await _refreshMissingAccountAvatar(accountId, token);
      await _logger.info(
        '[sync] trigger=manual-or-scheduled account_slot=account stage=request_succeeded status=${summary.failed == BigInt.zero ? 'success' : 'partial_failure'}',
      );
      for (final item in summary.errors) {
        await _logger.info(
          '[sync] trigger=manual-or-scheduled account_slot=account stage=media_download_failed failed_item=${sanitizeDiagnostic(item.message)}',
        );
      }
      try {
        await rust_api.recordSyncAttempt(
          accountId: accountId,
          status: summary.failed == BigInt.zero ? 'success' : 'partial_failure',
          totalFound: summary.totalFound,
          downloaded: summary.downloaded,
          duplicates: summary.duplicates,
          skippedRemote: summary.skippedRemote,
          failed: summary.failed,
        );
      } catch (historyError, stackTrace) {
        await logError(
          'Failed to persist account sync result',
          historyError,
          stackTrace,
        );
      }
      return summary;
    } catch (error, stackTrace) {
      await logError(
        '[sync] trigger=manual-or-scheduled account_slot=account stage=request_failed',
        error,
        stackTrace,
      );
      try {
        await rust_api.recordSyncAttempt(
          accountId: accountId,
          status: syncFailureStatus(error),
          totalFound: BigInt.zero,
          downloaded: BigInt.zero,
          duplicates: BigInt.zero,
          failed: BigInt.zero,
        );
      } catch (historyError) {
        await logError(
          'Failed to persist account sync result',
          historyError,
          stackTrace,
        );
      }
      rethrow;
    } finally {
      cleanup.remove();
    }
  }

  Future<void> _refreshMissingAccountAvatar(
    String accountId,
    String sessionToken,
  ) async {
    final cached = (await _readCachedProfiles())[accountId];
    if (cached?.avatarBytes?.isNotEmpty == true) return;
    try {
      final session = await rust_api.establishCoralSessionForAccount(
        sessionToken: sessionToken,
        expectedAccount: accountId,
        proxyUrl: _networkProxy,
      );
      await _cacheProfile(accountId, session, expectedToken: sessionToken);
    } catch (error) {
      // Avatar recovery is best effort and must never turn a successful
      // media synchronization into a failed synchronization.
      await _logger.info(
        '[sync] stage=account_avatar_refresh_failed account_slot=account reason=${sanitizeDiagnostic('$error')}',
      );
    }
  }

  @override
  Future<SyncScheduleStatus?> loadAccountSyncSchedule(String accountId) =>
      rust_api.syncScheduleStatus(accountId: accountId);

  @override
  Future<SyncScheduleStatus?> recordAccountSyncOutcome(
    String accountId, {
    required bool foundNewMedia,
  }) => rust_api.recordSyncOutcome(
    accountId: accountId,
    foundNewMedia: foundNewMedia,
  );

  @override
  Future<SyncProgress?> currentSyncProgress() => rust_api.currentSyncProgress();

  @override
  Future<bool> cancelSync() {
    _syncCancellationEpoch++;
    return rust_api.cancelCurrentSync();
  }

  @override
  Future<SyncScheduleStatus?> loadSyncScheduleStatus() async {
    final accountId = await selectedNintendoAccountId;
    if (accountId == null) return null;
    return rust_api.syncScheduleStatus(accountId: accountId);
  }

  @override
  Future<SyncScheduleStatus?> recordSyncOutcome({
    required bool foundNewMedia,
  }) async {
    final accountId = await selectedNintendoAccountId;
    if (accountId == null) return null;
    return rust_api.recordSyncOutcome(
      accountId: accountId,
      foundNewMedia: foundNewMedia,
    );
  }

  @override
  Future<SyncRuntimeState> loadSyncAccountHistory(String accountId) =>
      rust_api.syncAccountHistory(accountId: accountId);

  @override
  Future<void> signOut() => accountWorkGate.normal(_signOut);
  Future<void> _signOut() async {
    _requireAccountAccess();
    _accountMutationIntent++;
    _pendingLogin = null;
    await _commitAccounts(() async {
      final tokens = await _readStoredAccountTokens();
      final saved = await _storage.read(key: _selectedAccountKey);
      final selected = tokens.containsKey(saved)
          ? saved
          : tokens.isEmpty
          ? null
          : tokens.keys.first;
      if (selected != null) await _removeNintendoAccount(selected);
      await _storage.delete(key: _sessionTokenKey);
    });
  }

  void _requireAccountAccess() {
    if (_isolated) {
      throw StateError('Nintendo account access disabled in CI diagnostics');
    }
  }
}

Future<String> resolveDefaultLibraryPath(String supportDirectory) async {
  String? pictures;
  if (Platform.isWindows) {
    try {
      pictures = await PathProviderWindows().getPath(
        _windowsPicturesKnownFolderId,
      );
    } catch (_) {
      // Fall back to the application support directory below.
    }
  }
  return defaultLibraryPathForPlatform(
    supportDirectory: supportDirectory,
    isWindows: Platform.isWindows,
    picturesDirectory: pictures,
  );
}
