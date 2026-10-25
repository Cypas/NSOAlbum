import 'dart:typed_data';

import '../rust/models.dart';
import '../rust/settings.dart';

class NintendoAccountProfile {
  const NintendoAccountProfile({
    required this.accountId,
    required this.nickname,
    this.avatarUrl,
    this.avatarBytes,
  });

  final String accountId;
  final String nickname;
  final String? avatarUrl;
  final Uint8List? avatarBytes;
}

abstract interface class AppBackend {
  AppSettings get settings;

  String get logFilePath;

  Future<void> openLogFile();

  Future<void> openDirectory(String path);

  Future<void> logError(String message, Object error, [StackTrace? stackTrace]);

  Future<void> saveSettings(AppSettings value);

  Future<List<String>> importCustomFonts(List<String> sourcePaths);

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
  });

  Future<GalleryPage> listMediaPage(GalleryPageRequest request) =>
      Future.error(UnsupportedError('Media paging is unavailable'));

  Future<List<GameMediaCount>> listGameMediaCounts({int? albumId}) =>
      Future.error(UnsupportedError('Game media counts are unavailable'));

  Future<MediaDetails> loadMediaDetails(int mediaId) =>
      Future.error(UnsupportedError('Media details are unavailable'));

  Future<List<AlbumSummary>> listAlbums();

  Future<int> createAlbum(
    String name, {
    required String description,
    required bool smart,
  });

  Future<void> updateAlbum(
    int albumId,
    String name, {
    required String description,
    required bool smart,
  });

  Future<List<AlbumRule>> listAlbumRules(int albumId);

  Future<void> replaceAlbumRules(int albumId, List<AlbumRule> rules);

  Future<void> deleteAlbum(int albumId);

  Future<void> addMediaToAlbum(int albumId, int mediaId);

  Future<MediaDeletionResult> deleteMedia(int mediaId);

  Future<MediaDeletionResult> removeMediaFromAlbum(int albumId, int mediaId);

  Future<LibraryRelocationResult> relocateMediaLibrary(AppSettings settings);

  Future<ImportSummary> importLocalFiles(List<String> paths);

  Future<ImportSummary> importCustomFiles(List<String> paths, String gameName);

  Future<ImportSummary> importMtpFiles(List<String> paths, String deviceName);

  Future<MediaExportSummary> exportMedia(
    List<int> mediaIds,
    String destination,
    String nameFormat,
  );

  Future<MediaAsset> trimVideo(
    MediaAsset source,
    Duration start,
    Duration end, {
    required bool overwrite,
  });

  Future<MediaAsset> saveVideoFrame(
    MediaAsset source,
    Uint8List bytes,
    String extension,
  );

  Future<String> createMergedVideoPreview(List<MediaAsset> videos);

  Future<MediaAsset> saveMergedVideo(
    List<MediaAsset> videos, {
    String? preparedPath,
  });

  Future<void> discardTemporaryMedia(String path);

  Future<void> setFavorite(int mediaId, bool favorite);

  Future<List<String>> listTags();

  Future<List<TagUsageSummary>> listTagUsage();

  Future<int> createTag(String name);

  Future<void> renameTag(int tagId, String newName);

  Future<void> deleteTag(int tagId);

  Future<void> mergeTags(List<int> tagIds, String targetName);

  Future<List<GameTagSummary>> listGameTags();

  Future<List<GameTagAliasSummary>> listGameTagAliases();

  Future<void> recordGameTagSelection(String gameName);

  Future<void> mergeGameTags(List<String> gameNames, String targetName);

  Future<void> renameGameTag(String gameName, String targetName);

  Future<void> setNote(int mediaId, String note);

  Future<void> replaceTags(int mediaId, List<String> tags);

  Future<bool> get isSignedIn;

  Future<NintendoAccountProfile?> get nintendoAccountProfile;

  Future<List<NintendoAccountProfile>> listNintendoAccounts();

  Future<String?> get selectedNintendoAccountId;

  Future<void> selectNintendoAccount(String accountId);

  Future<void> removeNintendoAccount(String accountId);

  Future<void> beginNintendoLogin();

  Future<void> completeNintendoLogin(String callbackUrl);

  Future<void> signOut();

  Future<SyncSummary> syncNintendoAlbum();

  Future<SyncProgress?> currentSyncProgress();

  Future<bool> cancelSync();
}

abstract interface class SyncScheduleBackend {
  Future<SyncScheduleStatus?> loadSyncScheduleStatus();

  Future<SyncScheduleStatus?> recordSyncOutcome({required bool foundNewMedia});
}

abstract interface class SyncHistoryBackend {
  Future<SyncRuntimeState> loadSyncAccountHistory(String accountId);
}

abstract interface class SyncNotificationBackend {
  Future<void> notifyAutomaticSyncCompleted({
    required int downloaded,
    required int existing,
    required int failed,
    required int accountCount,
    int failedAccountCount = 0,
  });
}

/// Optional capabilities keep desktop and test backends source-compatible.
abstract interface class AccountSyncBackend {
  Future<SyncSummary> syncNintendoAccount(String accountId);
  Future<SyncScheduleStatus?> loadAccountSyncSchedule(String accountId);
  Future<SyncScheduleStatus?> recordAccountSyncOutcome(
    String accountId, {
    required bool foundNewMedia,
  });
}

class OperationProgressValue {
  const OperationProgressValue({
    required this.operationId,
    required this.kind,
    required this.phase,
    this.status = 'running',
    this.processed = 0,
    this.total,
    this.processedBytes,
    this.totalBytes,
    this.fraction,
  });
  final String operationId;
  final String kind;
  final String phase;
  final String status;
  final int processed;
  final int? total;
  final int? processedBytes;
  final int? totalBytes;
  final double? fraction;
  double? get value =>
      fraction?.clamp(0, 1) ??
      (total != null && total! > 0 ? (processed / total!).clamp(0, 1) : null);
}

abstract interface class OperationProgressBackend {
  Stream<OperationProgressValue> get operationProgress;
}

class MobileStorageLocation {
  const MobileStorageLocation({
    required this.id,
    required this.path,
    required this.removable,
  });
  final String id;
  final String path;
  final bool removable;
}

abstract interface class MobileStorageBackend {
  Future<List<MobileStorageLocation>> mobileStorageLocations();
}
