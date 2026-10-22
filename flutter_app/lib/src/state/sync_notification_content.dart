class SyncNotificationContent {
  const SyncNotificationContent({required this.title, required this.body});

  final String title;
  final String body;

  static SyncNotificationContent fromResult({
    required String language,
    required int downloaded,
    required int existing,
    required int failed,
    required int accountCount,
    int failedAccountCount = 0,
  }) {
    final isEnglish = language == 'en';
    final summary = isEnglish
        ? 'Added $downloaded · Existing $existing · Failed $failed'
        : '新增 $downloaded · 已存在 $existing · 失败 $failed';
    final accountSuffix = accountCount > 1
        ? isEnglish
              ? ' · $accountCount accounts'
              : ' · $accountCount 个账号'
        : '';
    final accountFailureSuffix = failedAccountCount > 0
        ? isEnglish
              ? ' · $failedAccountCount accounts incomplete'
              : ' · $failedAccountCount 个账号未完成'
        : '';
    return SyncNotificationContent(
      title: isEnglish ? 'NSOAlbum · Automatic sync complete' : '鱿型相册 · 自动同步完成',
      body: '$summary$accountSuffix$accountFailureSuffix',
    );
  }
}
