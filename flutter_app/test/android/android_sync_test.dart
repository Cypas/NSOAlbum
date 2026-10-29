@Tags(['platform-android'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/backend/app_backend.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/rust/settings.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/state/settings_copy.dart';
import 'package:squid_album/src/state/sync_controller.dart';
import 'package:squid_album/src/state/transfer_controller.dart';
import 'package:squid_album/src/ui/android/android_nintendo_sync_page.dart';
import 'package:squid_album/src/ui/android/android_settings_page.dart';
import 'package:squid_album/src/ui/android/android_theme.dart';
import 'package:squid_album/src/ui/platform_ui.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  for (final language in ['zh', 'en']) {
    for (final textScale in [1.0, 2.0]) {
      testWidgets(
        'automatic sync sleep dropdown offers desktop choices and saves in $language at ${textScale}x',
        (tester) async {
          final backend = await _pumpAutomaticSyncSettings(
            tester,
            language: language,
            textScale: textScale,
          );
          expect(find.byType(DropdownButtonFormField<int>), findsNWidgets(2));
          final sleep = find.byKey(const Key('android-nso-sleep-after'));
          await tester.ensureVisible(sleep);
          await tester.pumpAndSettle();
          await tester.tap(sleep);
          await tester.pumpAndSettle();
          for (final hours in [6, 12, 24, 48, 72]) {
            final option = find.text(
              language == 'zh' ? '$hours 小时' : '$hours hours',
            );
            expect(option, findsWidgets);
          }
          await tester.tap(
            find.text(language == 'zh' ? '6 小时' : '6 hours').last,
          );
          await tester.pumpAndSettle();
          expect(backend.settings.syncPolicy.sleepAfterHours, 6);
          expect(backend.settings.syncPolicy.activeIntervalMinutes, 30);
          expect(backend.settings.syncPolicy.enabled, isFalse);

          final interval = find.byKey(
            const Key('android-nso-auto-sync-interval'),
          );
          await tester.ensureVisible(interval);
          await tester.pumpAndSettle();
          await tester.tap(interval);
          await tester.pumpAndSettle();
          await tester.tap(
            find.text(language == 'zh' ? '45 分钟' : '45 minutes').last,
          );
          await tester.pumpAndSettle();
          expect(backend.settings.syncPolicy.activeIntervalMinutes, 45);
          expect(backend.settings.syncPolicy.sleepAfterHours, 6);
          expect(backend.settings.syncPolicy.enabled, isFalse);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({TargetPlatform.android}),
      );
    }
  }

  testWidgets(
    'automatic sync sleep preserves a legacy custom threshold until changed',
    (tester) async {
      final backend = await _pumpAutomaticSyncSettings(
        tester,
        sleepAfterHours: 18,
      );
      expect(find.byType(DropdownButtonFormField<int>), findsNWidgets(2));
      final sleep = find.byKey(const Key('android-nso-sleep-after'));
      await tester.ensureVisible(sleep);
      await tester.pumpAndSettle();
      expect(find.text('18 小时'), findsOneWidget);
      expect(backend.settings.syncPolicy.sleepAfterHours, 18);

      await tester.tap(sleep);
      await tester.pumpAndSettle();
      expect(find.text('18 小时'), findsWidgets);
      expect(find.text('24 小时'), findsWidgets);
      await tester.tap(find.text('24 小时').last);
      await tester.pumpAndSettle();
      expect(backend.settings.syncPolicy.sleepAfterHours, 24);
      expect(backend.settings.syncPolicy.activeIntervalMinutes, 30);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'automatic sync card groups and saves the notification preference',
    (tester) async {
      const notificationChannel = MethodChannel(
        'io.github.cypas.nsoalbum/notifications',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(notificationChannel, (call) async {
            if (call.method == 'notificationPermissionStatus') {
              return 'allowed';
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(notificationChannel, null),
      );
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
          home: AndroidSettingsPage(backend: backend, controller: settings),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('android-auto-sync-notifications')),
        180,
        scrollable: find.byType(Scrollable).last,
      );
      expect(
        find.byKey(const Key('android-auto-sync-notifications')),
        findsOneWidget,
      );
      final card = find.ancestor(
        of: find.byKey(const Key('android-auto-sync-notifications')),
        matching: find.byType(Card),
      );
      expect(card, findsOneWidget);
      expect(find.text('通知'), findsOneWidget);
      expect(settings.value.notifyOnAutoSync, isTrue);
      final notificationSwitch = find.byKey(
        const Key('android-auto-sync-notifications'),
      );
      final tile = tester.widget<SwitchListTile>(notificationSwitch);
      tile.onChanged!(false);
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
}

Future<FakeBackend> _pumpAutomaticSyncSettings(
  WidgetTester tester, {
  String language = 'zh',
  int sleepAfterHours = 24,
  double textScale = 1,
}) async {
  tester.view.physicalSize = const Size(320, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final backend = FakeBackend(signedIn: true, mediaItems: []);
  backend.settings = copyAppSettings(
    backend.settings,
    syncPolicy: SyncPolicy(
      enabled: false,
      activeIntervalMinutes: 30,
      sleepAfterHours: sleepAfterHours,
    ),
  );
  final settings = SettingsController(backend);
  final sync = SyncController(backend, allAccounts: true);
  final transfer = TransferController(backend, settings, sync);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    transfer.dispose();
    sync.dispose();
    settings.dispose();
  });
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
  return backend;
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
