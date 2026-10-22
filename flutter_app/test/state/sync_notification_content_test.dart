import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/state/sync_notification_content.dart';

void main() {
  test(
    'Chinese summary includes merged account count and all result counts',
    () {
      final content = SyncNotificationContent.fromResult(
        language: 'zh',
        downloaded: 5,
        existing: 6,
        failed: 3,
        accountCount: 2,
      );

      expect(content.title, '鱿型相册 · 自动同步完成');
      expect(content.body, '新增 5 · 已存在 6 · 失败 3 · 2 个账号');
    },
  );

  test(
    'English summary is localized and omits a redundant single-account suffix',
    () {
      final content = SyncNotificationContent.fromResult(
        language: 'en',
        downloaded: 1,
        existing: 0,
        failed: 0,
        accountCount: 1,
      );

      expect(content.title, 'NSOAlbum · Automatic sync complete');
      expect(content.body, 'Added 1 · Existing 0 · Failed 0');
    },
  );

  test('account failures are separate from actual failed media counts', () {
    final content = SyncNotificationContent.fromResult(
      language: 'zh',
      downloaded: 2,
      existing: 0,
      failed: 0,
      accountCount: 2,
      failedAccountCount: 1,
    );

    expect(content.body, '新增 2 · 已存在 0 · 失败 0 · 2 个账号 · 1 个账号未完成');
  });
}
