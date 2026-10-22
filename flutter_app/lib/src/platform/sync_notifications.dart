import 'package:flutter/services.dart';

import '../state/sync_notification_content.dart';

class SyncNotifications {
  SyncNotifications({required this.platform});

  final String platform;

  Future<void> show({
    required String language,
    required int downloaded,
    required int existing,
    required int failed,
    required int accountCount,
    int failedAccountCount = 0,
  }) async {
    if (downloaded <= 0) return;
    final content = SyncNotificationContent.fromResult(
      language: language,
      downloaded: downloaded,
      existing: existing,
      failed: failed,
      accountCount: accountCount,
      failedAccountCount: failedAccountCount,
    );
    if (platform == 'windows' || platform == 'android' || platform == 'macos') {
      await const MethodChannel('io.github.cypas.nsoalbum/notifications')
          .invokeMethod<void>('syncCompleted', {
            'downloaded': downloaded,
            'existing': existing,
            'failed': failed,
            'accounts': accountCount,
            'title': content.title,
            'body': content.body,
          });
    }
  }
}
