import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/backend/app_backend.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/rust/settings.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/state/sync_controller.dart';
import 'package:squid_album/src/state/transfer_controller.dart';
import 'package:squid_album/src/ui/android/android_transfer_page.dart';
import 'package:squid_album/src/ui/platform_ui.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  testWidgets('running sync displays readable counts and survives navigation', (
    tester,
  ) async {
    final gate = Completer<SyncSummary>();
    final backend = FakeBackend(
      mediaItems: [],
      signedIn: true,
      syncFuture: gate.future,
      syncProgress: SyncProgress(
        jobId: 'synthetic',
        status: 'running',
        totalItems: BigInt.from(5),
        processedItems: BigInt.from(2),
        synchronizedItems: BigInt.one,
        failedItems: BigInt.one,
      ),
    );
    await tester.pumpWidget(
      SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).at(2));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('android-sync-all')), findsOneWidget);
    expect(find.text('Player'), findsOneWidget);
    await tester.tap(find.byKey(const Key('android-sync-all')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('正在准备账号队列…'), findsOneWidget);
    expect(find.textContaining('当前媒体 2 / 5'), findsOneWidget);
    await tester.tap(find.byKey(const Key('android-sync-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('android-page-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('android-sync-entry')), findsOneWidget);
    expect(find.text('正在同步…'), findsOneWidget);
    expect(backend.syncCalls, 1);
    gate.complete(
      SyncSummary(
        jobId: 'synthetic',
        totalFound: BigInt.from(5),
        downloaded: BigInt.one,
        duplicates: BigInt.one,
        failed: BigInt.one,
        skippedRemote: BigInt.from(2),
        errors: const [],
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('login callback is preserved until sign-in page was opened', (
    tester,
  ) async {
    final backend = FakeBackend(mediaItems: []);
    await tester.pumpWidget(
      SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).at(2));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('android-sync-entry')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      'npf-test://auth?session_token_code=secret',
    );

    await tester.tap(find.text('完成登录'));
    await tester.pump();

    expect(find.text('请先打开登录页面后再输入回调地址。'), findsOneWidget);
    expect(
      find.text('npf-test://auth?session_token_code=secret'),
      findsOneWidget,
    );
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('login completion shows progress and disables duplicate submit', (
    tester,
  ) async {
    final backend = _DelayedLoginBackend();
    await tester.pumpWidget(
      SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).at(2));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('android-sync-entry')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('打开登录页面'),
      240,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('打开登录页面'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'npf-test://callback');

    await tester.tap(find.text('完成登录'));
    await tester.pump();

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '登录中，请稍后'),
    );
    expect(button.onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    backend.loginGate.complete();
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('cancel refreshes account history and shows localized feedback', (
    tester,
  ) async {
    final gate = Completer<SyncSummary>();
    final backend = _HistoryBackend(gate.future);
    await tester.pumpWidget(
      SquidAlbumApp(backend: backend, uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).at(2));
    await tester.pumpAndSettle();
    final initialLoads = backend.historyLoads;
    await tester.tap(find.byKey(const Key('android-sync-all')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('android-sync-all')));
    gate.complete(_summary('cancelled'));
    await tester.pumpAndSettle();

    expect(find.text('操作已取消。'), findsOneWidget);
    expect(backend.historyLoads, greaterThan(initialLoads));
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets(
    'account statuses and account progress distinguish partial and paused states',
    (tester) async {
      final backend = FakeBackend(
        mediaItems: [],
        signedIn: true,
        accountProfiles: const [
          NintendoAccountProfile(accountId: 'a', nickname: 'A'),
          NintendoAccountProfile(accountId: 'b', nickname: 'B'),
        ],
        accountSyncHistories: {
          'a': SyncRuntimeState(
            latestAttempt: SyncAttemptSummary(
              attemptedAt: DateTime.utc(2026, 10, 14),
              status: 'partial_failure',
              totalFound: BigInt.from(3),
              downloaded: BigInt.one,
              duplicates: BigInt.one,
              failed: BigInt.one,
            ),
          ),
          'b': SyncRuntimeState(
            latestAttempt: SyncAttemptSummary(
              attemptedAt: DateTime.utc(2026, 10, 14),
              status: 'authentication_failure',
              totalFound: BigInt.zero,
              downloaded: BigInt.zero,
              duplicates: BigInt.zero,
              failed: BigInt.one,
            ),
          ),
        },
      );
      final settings = SettingsController(backend);
      final sync = SyncController(backend, allAccounts: true)
        ..totalAccounts = 2
        ..completedAccounts = 1
        ..accountResults['a'] = SyncSummary(
          jobId: 'partial',
          totalFound: BigInt.from(3),
          downloaded: BigInt.one,
          duplicates: BigInt.one,
          skippedRemote: BigInt.zero,
          failed: BigInt.one,
          errors: const [],
        );
      final transfer = TransferController(backend, settings, sync);
      await transfer.refresh();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: AndroidTransferPage(controller: transfer),
        ),
      );
      await tester.pump();

      expect(find.text('同步完成但有部分项目失败'), findsOneWidget);
      expect(find.text('登录已失效，等待重新登录'), findsOneWidget);
      final accountBar = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('android-account-progress')),
      );
      expect(accountBar.value, .5);
      sync.accountResults.remove('a');
      sync.notifyListeners();
      await tester.pump();
      expect(find.text('上次同步有部分项目失败'), findsOneWidget);
      sync.state = SyncState.cancelled;
      sync.completedAccounts = 2;
      sync.notifyListeners();
      await tester.pump();
      expect(find.byKey(const Key('android-account-progress')), findsNothing);
      expect(find.byKey(const Key('android-media-progress')), findsNothing);
      expect(find.textContaining('账号同步已取消'), findsOneWidget);
      transfer.dispose();
      sync.dispose();
      settings.dispose();
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );
}

SyncSummary _summary(String id) => SyncSummary(
  jobId: id,
  totalFound: BigInt.zero,
  downloaded: BigInt.zero,
  duplicates: BigInt.zero,
  skippedRemote: BigInt.zero,
  failed: BigInt.zero,
  errors: const [],
);

class _DelayedLoginBackend extends FakeBackend {
  _DelayedLoginBackend() : super(mediaItems: []);
  final loginGate = Completer<void>();

  @override
  Future<void> completeNintendoLogin(String callbackUrl) async {
    await loginGate.future;
    signedIn = true;
  }
}

class _HistoryBackend extends FakeBackend {
  _HistoryBackend(Future<SyncSummary> syncFuture)
    : super(mediaItems: [], signedIn: true, syncFuture: syncFuture);
  int historyLoads = 0;

  @override
  Future<SyncRuntimeState> loadSyncAccountHistory(String accountId) async {
    historyLoads += 1;
    return const SyncRuntimeState();
  }
}
