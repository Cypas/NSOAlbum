import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:url_launcher/url_launcher.dart';

import '../rust/bridge.dart' as rust_api;
import '../rust/models.dart';
import '../rust/nso/provider.dart';
import '../rust/settings.dart';
import 'app_backend.dart';
import 'app_logger.dart';
import 'storage_paths.dart';
import '../fonts/custom_font_store.dart';
import '../rust/rust_initialization.dart';

const _windowsPicturesKnownFolderId = '{33E28130-4E1E-4676-835A-98395C3BC3BB}';

String interfaceLanguageForLocale(Locale locale) =>
    locale.languageCode.toLowerCase() == 'zh' ? 'zh' : 'en';

class RustBackend
    implements AppBackend, SyncScheduleBackend, SyncHistoryBackend {
  RustBackend._(this._storage, this._logger, this._libraryRoot);

  static const _sessionTokenKey = 'nintendo.session_token';
  static const _accountTokensKey = 'nintendo.account_tokens.v1';
  static const _accountProfilesKey = 'nintendo.account_profiles.v1';
  static const _selectedAccountKey = 'nintendo.selected_account.v1';
  final FlutterSecureStorage _storage;
  final AppLogger _logger;
  final String _libraryRoot;

  LoginChallenge? _pendingLogin;
  final Map<String, CoralSession> _coralSessions = {};
  AppSettings? _settings;

  static Future<RustBackend> open({
    FlutterSecureStorage? storage,
    AppLogger? logger,
    String? applicationRoot,
  }) async {
    await ensureRustLibInitialized();
    final supportDirectory = await getApplicationSupportDirectory();
    final libraryRoot =
        applicationRoot ?? await resolveApplicationRoot(supportDirectory.path);
    await rust_api.initCore(libraryRoot: libraryRoot);
    final appLogger = logger ?? AppLogger('$libraryRoot/logs/squid_album.log');
    await appLogger.ensureExists();
    final backend = RustBackend._(
      storage ?? const FlutterSecureStorage(),
      appLogger,
      libraryRoot,
    );
    await backend.loadSettings();
    await appLogger.info('Application core initialized');
    return backend;
  }

  @override
  AppSettings get settings => _settings!;

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
    final persisted = await rust_api.loadSettings();
    if (persisted != null) {
      _settings = persisted;
      return persisted;
    }
    final defaults = AppSettings(
      libraryPath: await resolveDefaultLibraryPath(_libraryRoot),
      theme: 'ocean',
      language: interfaceLanguageForLocale(PlatformDispatcher.instance.locale),
      galleryColumns: 4,
      galleryRows: 3,
      showNotePreview: true,
      showGameTag: true,
      compactTagDisplay: true,
      autoPlayVideo: false,
      autoSyncOnLaunch: false,
      closeBehavior: 'ask',
      customFontPaths: const [],
      syncPolicy: const SyncPolicy(
        enabled: false,
        activeIntervalMinutes: 10,
        sleepAfterHours: 24,
      ),
    );
    await rust_api.saveSettings(settings: defaults);
    _settings = defaults;
    return _settings!;
  }

  @override
  Future<void> saveSettings(AppSettings value) async {
    await rust_api.saveSettings(settings: value);
    _settings = value;
  }

  @override
  Future<List<String>> importCustomFonts(List<String> sourcePaths) async {
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
    DateTime? capturedFrom,
    DateTime? capturedUntil,
  }) => rust_api.listMedia(
    query: GalleryQuery(
      kind: kind,
      limit: limit,
      offset: offset,
      favoriteOnly: favoriteOnly,
      albumId: albumId,
      newestFirst: newestFirst,
      gameNames: gameNames,
      capturedFrom: capturedFrom,
      capturedUntil: capturedUntil,
    ),
  );

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
  Future<LibraryRelocationResult> relocateMediaLibrary(AppSettings settings) =>
      rust_api.relocateMediaLibrary(settings: settings);

  @override
  Future<ImportSummary> importLocalFiles(List<String> paths) =>
      rust_api.importLocalFiles(paths: paths);

  @override
  Future<ImportSummary> importCustomFiles(
    List<String> paths,
    String gameName,
  ) => rust_api.importCustomFiles(paths: paths, gameName: gameName);

  @override
  Future<ImportSummary> importMtpFiles(List<String> paths, String deviceName) =>
      rust_api.importMtpFiles(paths: paths, deviceName: deviceName);

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
      ]);
      return await rust_api.commitVideoEdit(
        mediaId: source.id,
        processedPath: output,
        overwrite: overwrite,
      );
    } finally {
      await discardTemporaryMedia(output);
    }
  }

  @override
  Future<MediaAsset> saveVideoFrame(
    MediaAsset source,
    Uint8List bytes,
    String extension,
  ) => rust_api.saveVideoFrame(
    mediaId: source.id,
    bytes: bytes,
    extension_: extension,
  );

  @override
  Future<String> createMergedVideoPreview(List<MediaAsset> videos) async {
    final sources = videos
        .where((item) => item.kind == MediaKind.video)
        .toList();
    if (sources.length < 2) {
      throw ArgumentError('At least two videos are required');
    }
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
      await _runFfmpeg(arguments);
      return output;
    } catch (_) {
      await discardTemporaryMedia(output);
      rethrow;
    }
  }

  @override
  Future<MediaAsset> saveMergedVideo(
    List<MediaAsset> videos, {
    String? preparedPath,
  }) async {
    final sources = videos
        .where((item) => item.kind == MediaKind.video)
        .toList();
    final output = preparedPath ?? await createMergedVideoPreview(sources);
    try {
      return await rust_api.commitMergedVideo(
        mediaIds: Int64List.fromList(sources.map((item) => item.id).toList()),
        processedPath: output,
      );
    } finally {
      await discardTemporaryMedia(output);
    }
  }

  @override
  Future<void> discardTemporaryMedia(String path) async {
    final root = Directory(
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}squid_album_video_processing',
    ).absolute.path;
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
    final root = Directory(
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}squid_album_video_processing',
    );
    await root.create(recursive: true);
    return '${root.path}${Platform.pathSeparator}$prefix-${DateTime.now().microsecondsSinceEpoch}.$extension';
  }

  Future<void> _runFfmpeg(List<String> arguments) async {
    final session = await FFmpegKit.executeWithArguments(arguments);
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
    final challenge = await rust_api.createNintendoLoginChallenge(
      proxyUrl: settings.proxyUrl,
    );
    _pendingLogin = challenge;
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
    return challenge;
  }

  @override
  Future<void> beginNintendoLogin() => _beginNintendoLogin();

  @override
  Future<void> completeNintendoLogin(String callbackUrl) async {
    final pending = _pendingLogin;
    if (pending == null) {
      throw StateError(
        settings.language == 'en'
            ? 'There is no pending Nintendo sign-in flow'
            : '没有待完成的 Nintendo 登录流程',
      );
    }
    final sessionToken = await rust_api.exchangeNintendoCallback(
      callbackUrl: callbackUrl,
      expectedState: pending.state,
      verifier: pending.verifier,
      proxyUrl: settings.proxyUrl,
    );
    final session = await rust_api.establishCoralSession(
      sessionToken: sessionToken,
      proxyUrl: settings.proxyUrl,
    );
    final accountId = _accountId(session);
    final tokens = await _readAccountTokens();
    tokens[accountId] = sessionToken;
    await _writeAccountTokens(tokens);
    await _storage.write(key: _selectedAccountKey, value: accountId);
    await _storage.delete(key: _sessionTokenKey);
    _coralSessions[accountId] = session;
    await _cacheProfile(accountId, session);
    _pendingLogin = null;
  }

  @override
  Future<bool> get isSignedIn async {
    if ((await _readStoredAccountTokens()).isNotEmpty) return true;
    return (await _storage.read(key: _sessionTokenKey))?.isNotEmpty == true;
  }

  @override
  Future<NintendoAccountProfile?> get nintendoAccountProfile async {
    final accountId = await selectedNintendoAccountId;
    if (accountId == null) return null;
    return (await _readCachedProfiles())[accountId];
  }

  @override
  Future<List<NintendoAccountProfile>> listNintendoAccounts() async {
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
  Future<String?> get selectedNintendoAccountId async {
    final tokens = await _readAccountTokens();
    if (tokens.isEmpty) return null;
    final selected = await _storage.read(key: _selectedAccountKey);
    if (selected != null && tokens.containsKey(selected)) return selected;
    final fallback = tokens.keys.first;
    await _storage.write(key: _selectedAccountKey, value: fallback);
    return fallback;
  }

  @override
  Future<void> selectNintendoAccount(String accountId) async {
    final tokens = await _readAccountTokens();
    if (!tokens.containsKey(accountId)) {
      throw StateError('Nintendo account is no longer available');
    }
    await _storage.write(key: _selectedAccountKey, value: accountId);
  }

  @override
  Future<void> removeNintendoAccount(String accountId) async {
    final tokens = await _readAccountTokens();
    tokens.remove(accountId);
    _coralSessions.remove(accountId);
    final profiles = await _readCachedProfiles();
    profiles.remove(accountId);
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

  Future<CoralSession> _validCoralSessionFor(
    String accountId,
    String sessionToken, {
    bool forceRefresh = false,
  }) async {
    final now = DateTime.now().toUtc();
    final cached = _coralSessions[accountId];
    if (!forceRefresh &&
        cached != null &&
        (cached.expiresAt == null || cached.expiresAt!.isAfter(now))) {
      return cached;
    }
    final session = await rust_api.establishCoralSession(
      sessionToken: sessionToken,
      proxyUrl: settings.proxyUrl,
    );
    _coralSessions[accountId] = session;
    return session;
  }

  Future<Map<String, String>> _readStoredAccountTokens() async {
    final raw = await _storage.read(key: _accountTokensKey);
    if (raw == null || raw.isEmpty) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return {};
    return decoded.map(
      (key, value) => MapEntry(key, value is String ? value : ''),
    )..removeWhere((_, value) => value.isEmpty);
  }

  Future<Map<String, String>> _readAccountTokens() async {
    final tokens = await _readStoredAccountTokens();
    if (tokens.isNotEmpty) return tokens;
    final legacy = await _storage.read(key: _sessionTokenKey);
    if (legacy == null || legacy.isEmpty) return tokens;
    final session = await rust_api.establishCoralSession(
      sessionToken: legacy,
      proxyUrl: settings.proxyUrl,
    );
    final accountId = _accountId(session);
    tokens[accountId] = legacy;
    _coralSessions[accountId] = session;
    await _cacheProfile(accountId, session);
    await _writeAccountTokens(tokens);
    await _storage.write(key: _selectedAccountKey, value: accountId);
    await _storage.delete(key: _sessionTokenKey);
    return tokens;
  }

  Future<void> _writeAccountTokens(Map<String, String> tokens) async {
    if (tokens.isEmpty) {
      await _storage.delete(key: _accountTokensKey);
      return;
    }
    await _storage.write(key: _accountTokensKey, value: jsonEncode(tokens));
  }

  Future<Map<String, NintendoAccountProfile>> _readCachedProfiles() async {
    final raw = await _storage.read(key: _accountProfilesKey);
    if (raw == null || raw.isEmpty) return {};
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
    if (profiles.isEmpty) {
      await _storage.delete(key: _accountProfilesKey);
      return;
    }
    final encoded = profiles.map(
      (accountId, profile) => MapEntry(accountId, {
        'nickname': profile.nickname,
        'avatar_url': profile.avatarUrl,
        'avatar_base64': profile.avatarBytes == null
            ? null
            : base64Encode(profile.avatarBytes!),
      }),
    );
    await _storage.write(key: _accountProfilesKey, value: jsonEncode(encoded));
  }

  Future<void> _cacheProfile(String accountId, CoralSession session) async {
    final profiles = await _readCachedProfiles();
    profiles[accountId] = _profileFromSession(accountId, session);
    await _writeCachedProfiles(profiles);
  }

  String _accountId(CoralSession session) {
    final value = session.naId ?? session.coralUserId;
    if (value == null || value.trim().isEmpty) {
      throw StateError('Nintendo session did not include an account ID');
    }
    return value.trim();
  }

  @override
  Future<SyncSummary> syncNintendoAlbum() async {
    final tokens = await _readAccountTokens();
    final accountId = await selectedNintendoAccountId;
    if (accountId == null || tokens[accountId] == null) {
      throw StateError(
        settings.language == 'en'
            ? 'Sign in to Nintendo Account first'
            : '请先登录 Nintendo Account',
      );
    }
    final SyncSummary summary;
    try {
      final session = await _validCoralSessionFor(
        accountId,
        tokens[accountId]!,
        forceRefresh: true,
      );
      await _cacheProfile(accountId, session);
      summary = await rust_api.syncNso(
        session: session,
        proxyUrl: settings.proxyUrl,
      );
    } catch (error) {
      final message = error.toString().toLowerCase();
      final cancelled = message.contains('cancelled');
      try {
        await rust_api.recordSyncAttempt(
          accountId: accountId,
          status: cancelled ? 'cancelled' : 'failure',
          totalFound: BigInt.zero,
          downloaded: BigInt.zero,
          duplicates: BigInt.zero,
          failed: BigInt.zero,
        );
      } catch (historyError, stackTrace) {
        await logError(
          'Failed to persist Nintendo sync failure history',
          historyError,
          stackTrace,
        );
      }
      rethrow;
    }

    final failed = summary.failed.toInt();
    try {
      await rust_api.recordSyncAttempt(
        accountId: accountId,
        status: failed == 0 ? 'success' : 'partial_failure',
        totalFound: summary.totalFound,
        downloaded: summary.downloaded,
        duplicates: summary.duplicates + summary.skippedRemote,
        failed: summary.failed,
      );
    } catch (error, stackTrace) {
      await logError(
        'Failed to persist Nintendo sync result history',
        error,
        stackTrace,
      );
    }
    return summary;
  }

  @override
  Future<SyncProgress?> currentSyncProgress() => rust_api.currentSyncProgress();

  @override
  Future<bool> cancelSync() => rust_api.cancelCurrentSync();

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
  Future<void> signOut() async {
    _pendingLogin = null;
    final selected = await selectedNintendoAccountId;
    if (selected != null) await removeNintendoAccount(selected);
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
