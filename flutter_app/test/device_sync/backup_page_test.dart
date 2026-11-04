import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/service_contract.dart';
import 'package:squid_album/src/rust/device_sync/read_model.dart' as read;
import 'package:squid_album/src/ui/device_sync/backup_page.dart';

import 'device_sync_page_test.dart' show pageApp;
import 'session_panel_test.dart' show counts;

void main() {
  testWidgets(
    'account preview decline reads no account changes and restore needs click',
    (tester) async {
      final browser = BackupBrowser();
      var refreshes = 0;
      await tester.pumpWidget(
        pageApp(
          builder: (_) => DeviceSyncBackupPage(
            browser: browser,
            mobile: false,
            onLibraryChanged: () async => refreshes++,
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-page')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Unknown account scope'), findsOneWidget);
      expect(find.textContaining('2026-10-17 12:34:56'), findsOneWidget);
      await tester.tap(find.byKey(const Key('device-backup-preview-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('device-decline-account-preview')));
      await tester.pumpAndSettle();
      expect(browser.prepared, isEmpty);
      await tester.tap(find.byKey(const Key('device-backup-preview-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('device-allow-account-preview')));
      await tester.pumpAndSettle();
      expect(browser.prepared, [true]);
      expect(browser.confirmed, isEmpty);
      await tester.ensureVisible(
        find.byKey(const Key('device-confirm-restore')),
      );
      await tester.tap(find.byKey(const Key('device-confirm-restore')));
      await tester.pumpAndSettle();
      expect(browser.confirmed, [browser.shown]);
      expect(refreshes, 1);
      expect(find.textContaining('Restore complete'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(browser.closed, isTrue);
    },
  );
}

class BackupBrowser extends DeviceBackupBrowserController {
  bool retired = false;
  bool drained = false;
  final prepared = <bool>[];
  final confirmed = <DeviceRestorePreviewView>[];
  Future<void>? closeWait;
  final shown = DeviceRestorePreviewView(
    library: read.RestoreSummary(
      binding: 'private-binding',
      currentDigest: 'private-current',
      restoredDigest: 'private-backup',
      media: counts,
      albums: counts,
      includesAccounts: true,
    ),
    accounts: const DeviceAccountCounts(added: 1, replaced: 2, removed: 3),
  );
  DeviceRestorePreviewView? current;
  @override
  bool get closed => retired;
  @override
  bool get settled => drained;
  @override
  bool get busy => false;
  @override
  DeviceRestorePreviewView? get preview => current;
  @override
  Future<DeviceBackupPageView> page({
    String? cursor,
  }) async => DeviceBackupPageView(
    items: [
      DeviceBackupEntry(
        read.BackupMetadata(
          backup: 'synthetic-backup',
          sourceName: 'Desktop',
          includesAccounts: true,
          createdAt: DateTime(2026, 10, 17, 12, 34, 56, 789).toIso8601String(),
        ),
      ),
      const DeviceBackupEntry(
        read.BackupMetadata(backup: 'unknown-scope', includesAccounts: null),
      ),
    ],
  );
  @override
  Future<DeviceRestorePreviewView> prepareRestore(
    DeviceBackupEntry entry, {
    bool accountsAuthorized = false,
  }) async {
    prepared.add(accountsAuthorized);
    return current = shown;
  }

  @override
  Future<DeviceRestoreResult> confirmRestore(
    DeviceRestorePreviewView shown,
  ) async {
    confirmed.add(shown);
    current = null;
    return const DeviceRestoreResult(finalized: true, cleanupPending: false);
  }

  @override
  Future<void> discardPreview() async => current = null;
  @override
  Future<void> close() async {
    retired = true;
    current = null;
    await closeWait;
    drained = true;
  }
}
