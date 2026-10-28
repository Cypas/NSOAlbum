import '../rust/settings.dart';

AppSettings copyAppSettings(
  AppSettings value, {
  String? theme,
  String? language,
  bool? dohEnabled,
  int? galleryColumns,
  bool? showNotePreview,
  bool? showGameTag,
  bool? compactTagDisplay,
  bool? autoPlayVideo,
  bool? autoSyncOnLaunch,
  bool? notifyOnAutoSync,
  bool? showSplatoonSchedule,
  bool? showSplatoonFriendActivity,
  String? proxyUrl,
  String? libraryPath,
  SyncPolicy? syncPolicy,
}) => AppSettings(
  proxyUrl: proxyUrl == null
      ? value.proxyUrl
      : (proxyUrl.isEmpty ? null : proxyUrl),
  dohEnabled: dohEnabled ?? value.dohEnabled,
  libraryPath: libraryPath ?? value.libraryPath,
  theme: theme ?? value.theme,
  language: language ?? value.language,
  galleryColumns: galleryColumns ?? value.galleryColumns,
  galleryRows: value.galleryRows,
  showNotePreview: showNotePreview ?? value.showNotePreview,
  showGameTag: showGameTag ?? value.showGameTag,
  compactTagDisplay: compactTagDisplay ?? value.compactTagDisplay,
  autoPlayVideo: autoPlayVideo ?? value.autoPlayVideo,
  autoSyncOnLaunch: autoSyncOnLaunch ?? value.autoSyncOnLaunch,
  notifyOnAutoSync: notifyOnAutoSync ?? value.notifyOnAutoSync,
  showSplatoonSchedule: showSplatoonSchedule ?? value.showSplatoonSchedule,
  showSplatoonFriendActivity:
      showSplatoonFriendActivity ?? value.showSplatoonFriendActivity,
  closeBehavior: value.closeBehavior,
  customFontPaths: value.customFontPaths,
  syncPolicy: syncPolicy ?? value.syncPolicy,
);
