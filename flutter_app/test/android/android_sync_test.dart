@Tags(['platform-android'])
library;

import 'dart:async';
import 'dart:convert';

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
import 'package:squid_album/src/ui/android/android_nintendo_sync_page.dart';
import 'package:squid_album/src/ui/android/android_theme.dart';
import 'package:squid_album/src/ui/platform_ui.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  for (final language in ['zh', 'en']) {
    for (final textScale in [1.0, 2.0]) {
      testWidgets(
        'automatic sync input labels stay separate in $language at ${textScale}x',
        (tester) async {
          tester.view.physicalSize = const Size(320, 1400);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final backend = FakeBackend(signedIn: true, mediaItems: []);
          final settings = SettingsController(backend);
          final sync = SyncController(backend, allAccounts: true);
          final transfer = TransferController(backend, settings, sync);
          addTearDown(transfer.dispose);
          addTearDown(sync.dispose);
          addTearDown(settings.dispose);
          await transfer.refresh();
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(language),
              theme: androidTheme('ocean'),
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
              home: AndroidNintendoSyncPage(controller: transfer),
            ),
          );
          await tester.pumpAndSettle();
          final sleepLabel = find.text(
            language == 'zh'
                ? '无新媒体后进入休眠（小时）'
                : 'Sleep after no new media (hours)',
          );
          await tester.ensureVisible(sleepLabel);
          await tester.pumpAndSettle();
          final interval = find.byType(DropdownButtonFormField<int>);
          expect(
            tester.getTopLeft(sleepLabel).dy,
            greaterThan(tester.getBottomLeft(interval).dy),
            reason:
                'The floating sleep label must not touch the interval field.',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        variant: TargetPlatformVariant({TargetPlatform.android}),
      );
    }
  }

  testWidgets(
    'automatic sync card groups and saves the notification preference',
    (tester) async {
      final backend = FakeBackend(signedIn: true, mediaItems: []);
      final settings = SettingsController(backend);
      final sync = SyncController(backend, allAccounts: true);
      final transfer = TransferController(backend, settings, sync);
      addTearDown(transfer.dispose);
      addTearDown(sync.dispose);
      addTearDown(settings.dispose);
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
          home: AndroidNintendoSyncPage(controller: transfer),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('自动同步设置'),
        180,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('同步完成后通知'), findsOneWidget);
      final card = find.ancestor(
        of: find.text('同步完成后通知'),
        matching: find.byType(Card),
      );
      expect(card, findsOneWidget);
      for (final text in [
        '自动同步设置',
        '启用自动同步策略',
        '启动时自动同步',
        '活跃期检查周期',
        '无新媒体后进入休眠（小时）',
      ]) {
        expect(
          find.descendant(of: card, matching: find.text(text)),
          findsOneWidget,
        );
      }
      expect(settings.value.notifyOnAutoSync, isTrue);
      await tester.ensureVisible(find.text('同步完成后通知'));
      await tester.tap(find.text('同步完成后通知'));
      await tester.pumpAndSettle();
      expect(settings.value.notifyOnAutoSync, isFalse);
      expect(backend.settings.notifyOnAutoSync, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets('Nintendo sync account avatar opens a preview and save action', (
    tester,
  ) async {
    final backend = FakeBackend(
      signedIn: true,
      mediaItems: [],
      accountProfiles: [
        NintendoAccountProfile(
          accountId: 'avatar-account',
          nickname: 'Avatar account',
          avatarBytes: base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
        ),
      ],
    );
    final settings = SettingsController(backend);
    final sync = SyncController(backend, allAccounts: true);
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
        home: AndroidNintendoSyncPage(controller: transfer),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('android-sync-avatar-avatar-account')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Avatar account'), findsNWidgets(2));
    expect(find.byKey(const Key('app-image-viewer-pages')), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byKey(const Key('app-image-viewer-save')), findsOneWidget);
    transfer.dispose();
    sync.dispose();
    settings.dispose();
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

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
    expect(find.byKey(const Key('android-media-progress')), findsNothing);
    expect(find.textContaining('已连接 1 个账号'), findsNothing);
    expect(find.byKey(const Key('android-sync-all')), findsOneWidget);
    expect(find.text('Player'), findsOneWidget);
    await tester.tap(find.byKey(const Key('android-sync-all')));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('正在同步…'), findsWidgets);
    expect(find.textContaining('已连接 1 个账号'), findsNothing);
    expect(find.textContaining('当前媒体 2 / 5'), findsOneWidget);
    await tester.tap(find.byKey(const Key('android-sync-entry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('android-media-progress')), findsNothing);
    await tester.tap(find.byKey(const Key('android-page-back')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('android-sync-entry')), findsOneWidget);
    expect(find.text('正在同步…'), findsWidgets);
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
    expect(find.byKey(const Key('android-media-progress')), findsNothing);
    expect(find.textContaining('账号 1 / 1'), findsNothing);
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
    'account statuses use text and traffic-light colors with one progress bar',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final backend = FakeBackend(
        mediaItems: [],
        signedIn: true,
        accountProfiles: const [
          NintendoAccountProfile(accountId: 'a', nickname: 'A'),
          NintendoAccountProfile(accountId: 'b', nickname: 'B'),
          NintendoAccountProfile(accountId: 'c', nickname: 'C'),
          NintendoAccountProfile(accountId: 'd', nickname: 'D'),
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
          'c': SyncRuntimeState(
            latestAttempt: SyncAttemptSummary(
              attemptedAt: DateTime.utc(2026, 10, 14, 1, 2, 3, 456, 789),
              status: 'success',
              totalFound: BigInt.one,
              downloaded: BigInt.one,
              duplicates: BigInt.zero,
              failed: BigInt.zero,
            ),
          ),
          'd': SyncRuntimeState(
            latestAttempt: SyncAttemptSummary(
              attemptedAt: DateTime.utc(2026, 10, 14),
              status: 'cancelled',
              totalFound: BigInt.zero,
              downloaded: BigInt.zero,
              duplicates: BigInt.zero,
              failed: BigInt.zero,
            ),
          ),
        },
      );
      final settings = SettingsController(backend);
      final sync = SyncController(backend, allAccounts: true)
        ..state = SyncState.running
        ..totalAccounts = 4
        ..completedAccounts = 1
        ..progress = SyncProgress(
          jobId: 'partial',
          status: 'running',
          totalItems: BigInt.from(4),
          processedItems: BigInt.one,
          synchronizedItems: BigInt.one,
          failedItems: BigInt.zero,
        )
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
      expect(find.text('上次同步成功'), findsOneWidget);
      expect(find.text('上次同步已取消'), findsOneWidget);
      expect(find.byKey(const Key('android-account-progress')), findsNothing);
      expect(_statusDotColor(tester, 'a'), Colors.amber.shade700);
      expect(_statusDotColor(tester, 'b'), Colors.red.shade600);
      expect(_statusDotColor(tester, 'c'), Colors.green.shade600);
      expect(_statusDotColor(tester, 'd'), Colors.grey.shade600);
      expect(find.bySemanticsLabel(RegExp('同步完成但有部分项目失败')), findsOneWidget);
      expect(find.textContaining('上次尝试：'), findsNWidgets(4));
      expect(find.textContaining('2026-'), findsNothing);
      expect(find.textContaining(RegExp(r'\.\d{3}')), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const Key('android-media-progress')),
        160,
      );
      final mediaBar = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('android-media-progress')),
      );
      expect(mediaBar.value, .25);
      await tester.scrollUntilVisible(
        find.byKey(const Key('android-account-status-dot-a')),
        -160,
      );

      sync.currentAccountId = 'a';
      sync.state = SyncState.running;
      sync.notifyListeners();
      await tester.pump();
      expect(find.text('正在同步'), findsOneWidget);
      expect(_statusDotColor(tester, 'a'), Colors.blue.shade600);

      sync.state = SyncState.cancelling;
      sync.notifyListeners();
      await tester.pump();
      expect(find.text('正在取消同步'), findsOneWidget);
      expect(_statusDotColor(tester, 'a'), Colors.blue.shade600);

      sync.currentAccountId = null;
      sync.state = SyncState.completed;
      sync.accountResults.remove('a');
      sync.notifyListeners();
      await tester.pump();
      expect(find.text('上次同步有部分项目失败'), findsOneWidget);
      expect(_statusDotColor(tester, 'a'), Colors.amber.shade700);
      sync.state = SyncState.cancelled;
      sync.completedAccounts = 4;
      sync.notifyListeners();
      await tester.pump();
      expect(find.byKey(const Key('android-account-progress')), findsNothing);
      expect(find.byKey(const Key('android-media-progress')), findsNothing);
      expect(find.textContaining('账号同步已取消'), findsNothing);
      expect(find.text('上次同步已取消'), findsOneWidget);
      transfer.dispose();
      sync.dispose();
      settings.dispose();
      semantics.dispose();
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  for (final locale in ['zh', 'en']) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'account states retain meaning at 320dp and 2x text in $locale $brightness',
        (tester) async {
          tester.view.physicalSize = const Size(320, 1800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final backend = FakeBackend(
            signedIn: true,
            mediaItems: [],
            accountProfiles: const [
              NintendoAccountProfile(
                accountId: 'a',
                nickname: '很长的完整用户名 Long Nintendo Account Display Name',
              ),
            ],
          );
          final settings = SettingsController(backend);
          final sync = SyncController(backend, allAccounts: true)
            ..state = SyncState.running
            ..totalAccounts = 1;
          final transfer = TransferController(backend, settings, sync);
          await transfer.refresh();
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(locale),
              theme: ThemeData(brightness: brightness),
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(2)),
                child: child!,
              ),
              home: AndroidTransferPage(controller: transfer),
            ),
          );
          await tester.pump();
          final name = find.text('很长的完整用户名 Long Nintendo Account Display Name');
          expect(tester.widget<Text>(name).maxLines, isNull);
          expect(
            tester.getTopLeft(name).dy,
            greaterThan(
              tester.getBottomLeft(find.byType(CircleAvatar).first).dy,
            ),
          );

          final scenarios = [
            (
              history: 'success',
              error: null,
              zh: '上次同步成功',
              en: 'Last sync succeeded',
              color: Colors.green.shade600,
            ),
            (
              history: 'partial_failure',
              error: null,
              zh: '上次同步有部分项目失败',
              en: 'Last sync had some failed items',
              color: Colors.amber.shade700,
            ),
            (
              history: 'failure',
              error: null,
              zh: '上次同步未完成',
              en: 'Last sync did not complete',
              color: Colors.red.shade600,
            ),
            (
              history: 'authentication_failure',
              error: null,
              zh: '登录已失效，等待重新登录',
              en: 'Sign-in expired; waiting for sign-in',
              color: Colors.red.shade600,
            ),
            (
              history: 'rate_limited',
              error: null,
              zh: '请求过于频繁，等待重试',
              en: 'Rate limited; waiting to retry',
              color: Colors.amber.shade700,
            ),
            (
              history: 'cancelled',
              error: null,
              zh: '上次同步已取消',
              en: 'Last sync was cancelled',
              color: Colors.grey.shade600,
            ),
            (
              history: null,
              error: null,
              zh: '等待同步',
              en: 'Waiting to sync',
              color: Colors.grey.shade600,
            ),
            (
              history: 'success',
              error: StateError('HTTP 429'),
              zh: '请求过于频繁，等待重试',
              en: 'Rate limited; waiting to retry',
              color: Colors.amber.shade700,
            ),
            (
              history: 'success',
              error: StateError('network timeout'),
              zh: '网络请求失败，请检查连接后重试。',
              en: 'Network request failed. Check your connection and try again.',
              color: Colors.red.shade600,
            ),
            (
              history: 'success',
              error: StateError('authentication failed'),
              zh: '登录已失效，等待重新登录',
              en: 'Sign-in expired; waiting for sign-in',
              color: Colors.red.shade600,
            ),
            (
              history: 'success',
              error: StateError('task cancelled'),
              zh: '同步已取消',
              en: 'Sync cancelled',
              color: Colors.grey.shade600,
            ),
          ];
          for (final scenario in scenarios) {
            transfer.histories['a'] = SyncRuntimeState(
              latestAttempt: scenario.history == null
                  ? null
                  : SyncAttemptSummary(
                      attemptedAt: DateTime(2026, 1, 2, 3, 4, 5, 999, 999),
                      status: scenario.history!,
                      totalFound: BigInt.zero,
                      downloaded: BigInt.zero,
                      duplicates: BigInt.zero,
                      failed: BigInt.zero,
                    ),
            );
            sync.accountErrors.clear();
            if (scenario.error != null) {
              sync.accountErrors['a'] = scenario.error!;
            }
            transfer.publish();
            await tester.pump();
            expect(
              find.text(locale == 'zh' ? scenario.zh : scenario.en),
              findsOneWidget,
            );
            expect(_statusDotColor(tester, 'a'), scenario.color);
            expect(
              find.byKey(const Key('android-account-progress')),
              findsNothing,
            );
            await tester.scrollUntilVisible(
              find.byKey(const Key('android-media-progress')),
              160,
              scrollable: find.byType(Scrollable).first,
            );
            expect(
              tester
                  .widget<LinearProgressIndicator>(
                    find.byKey(const Key('android-media-progress')),
                  )
                  .value,
              isNull,
            );
            if (scenario.history != null) {
              expect(
                find.text(
                  '${locale == 'zh' ? '上次尝试：' : 'Last attempt: '}01-02 03:04',
                ),
                findsOneWidget,
              );
            }
            expect(tester.takeException(), isNull);
          }

          // Authentication pause supersedes even a retained successful result.
          sync.accountErrors.clear();
          sync.accountResults['a'] = _summary('complete');
          sync.authPausedAccountIds.add('a');
          sync.notifyListeners();
          await tester.pump();
          expect(_statusDotColor(tester, 'a'), Colors.red.shade600);
          expect(
            find.text(
              locale == 'zh'
                  ? '登录已失效，等待重新登录'
                  : 'Sign-in expired; waiting for sign-in',
            ),
            findsOneWidget,
          );
          sync.authPausedAccountIds.clear();
          sync.notifyListeners();
          await tester.pump();
          expect(_statusDotColor(tester, 'a'), Colors.green.shade600);
          expect(
            find.text(locale == 'zh' ? '同步完成' : 'Sync complete'),
            findsOneWidget,
          );

          await tester.ensureVisible(
            find.byKey(const Key('android-sync-entry')),
          );
          await tester.pump();
          await tester.tap(find.byKey(const Key('android-sync-entry')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(
            find.descendant(
              of: find.byType(AndroidNintendoSyncPage),
              matching: find.textContaining('01-02 03:04'),
            ),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const Key('android-page-back')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(_statusDotColor(tester, 'a'), Colors.green.shade600);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          transfer.dispose();
          sync.dispose();
          settings.dispose();
        },
        variant: TargetPlatformVariant({TargetPlatform.android}),
      );
    }
  }
}

Color _statusDotColor(WidgetTester tester, String accountId) {
  final decoration =
      tester
              .widget<Container>(
                find.byKey(Key('android-account-status-dot-$accountId')),
              )
              .decoration!
          as BoxDecoration;
  return decoration.color!;
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
