@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/app_backend.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/rust/settings.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/state/sync_controller.dart';
import 'package:squid_album/src/state/transfer_controller.dart';
import 'package:squid_album/src/ui/android/android_account_expander.dart';
import 'package:squid_album/src/ui/android/android_transfer_page.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  for (final width in [320.0, 360.0, 412.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final locale in ['zh', 'en']) {
        testWidgets('account identity stays left of sync details at ${width}dp '
            '${scale}x in $locale', (tester) async {
          tester.view.physicalSize = Size(width, 2200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final nickname = scale == 1
              ? 'keo'
              : '很长的完整用户名 Long Nintendo Account Display Name';
          final backend = FakeBackend(
            signedIn: true,
            mediaItems: [],
            accountProfiles: [
              NintendoAccountProfile(accountId: 'a', nickname: nickname),
            ],
            accountSyncHistories: {
              'a': SyncRuntimeState(
                latestAttempt: SyncAttemptSummary(
                  attemptedAt: DateTime(2026, 10, 16, 3, 28, 59, 999, 999),
                  status: 'success',
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
            ..state = SyncState.completed
            ..accountResults['a'] = SyncSummary(
              jobId: 'layout',
              totalFound: BigInt.zero,
              downloaded: BigInt.zero,
              duplicates: BigInt.zero,
              skippedRemote: BigInt.zero,
              failed: BigInt.zero,
              errors: const [],
            );
          final transfer = TransferController(backend, settings, sync);
          await transfer.refresh();
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(locale),
              theme: ThemeData(
                brightness: scale == 1 ? Brightness.light : Brightness.dark,
              ),
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: AndroidTransferPage(controller: transfer),
            ),
          );
          await tester.pumpAndSettle();

          final avatar = tester.getRect(find.byType(CircleAvatar));
          final name = find.text(nickname);
          final nameRect = tester.getRect(name);
          final status = tester.getRect(
            find.text(locale == 'zh' ? '同步完成' : 'Sync complete'),
          );
          final attemptText = find.textContaining(
            locale == 'zh' ? '上次尝试：' : 'Last attempt: ',
          );
          final attempt = tester.getRect(attemptText);
          final details = tester.getRect(
            find.ancestor(of: attemptText, matching: find.byType(Column)).first,
          );
          final result = tester.getRect(
            find.text(
              locale == 'zh'
                  ? '下载 0 · 重复 0 · 失败 0'
                  : 'Downloaded 0 · Duplicates 0 · Failed 0',
            ),
          );
          expect(status.left, greaterThan(nameRect.right));
          expect(status.top, lessThan(avatar.bottom));
          expect(attempt.left, greaterThan(nameRect.right));
          expect(result.left, greaterThan(nameRect.right));
          expect(nameRect.top, greaterThan(avatar.bottom));
          expect(nameRect.center.dx, closeTo(avatar.center.dx, .1));
          expect(nameRect.width, lessThanOrEqualTo(88));
          if (scale == 2) {
            expect(nameRect.width, greaterThanOrEqualTo(80));
          }
          expect(
            find.text(
              locale == 'zh' ? '上次尝试：10-16 03:28' : 'Last attempt: 10-16 03:28',
            ),
            findsOneWidget,
          );
          expect(tester.widget<Text>(name).maxLines, isNull);
          expect(
            tester.widget<Text>(name).overflow,
            isNot(TextOverflow.ellipsis),
          );
          final account = find.byKey(const PageStorageKey('android-account-a'));
          final accountRect = tester.getRect(account);
          final arrow = tester.getRect(find.byIcon(Icons.expand_more));
          expect(avatar.left - accountRect.left, lessThanOrEqualTo(30));
          expect(accountRect.right - arrow.right, lessThanOrEqualTo(10));
          expect(arrow.left - details.right, inInclusiveRange(0, 8));
          // Ahem test glyphs are not Android fonts; assert usable width rather
          // than predicting real-device line breaks from the test font.
          expect(details.width, greaterThanOrEqualTo(accountRect.width - 132));
          expect(arrow.center.dy, closeTo(accountRect.center.dy, .1));
          expect(tester.takeException(), isNull);

          if (scale == 1) {
            final semantics = tester.ensureSemantics();
            expect(
              find.text(locale == 'zh' ? '好友列表' : 'Friends'),
              findsNothing,
            );
            // The header, not just its decorative arrow, is the tap target.
            for (final target in [
              find.byType(CircleAvatar),
              name,
              find.text(locale == 'zh' ? '同步完成' : 'Sync complete'),
              find.byIcon(Icons.expand_more),
            ]) {
              await tester.tap(target);
              await tester.pumpAndSettle();
              final expanded = find.bySemanticsLabel(
                RegExp(
                  'keo[\\s\\S]*${locale == 'zh' ? '同步完成' : 'Sync complete'}',
                ),
              );
              expect(expanded, findsOneWidget);
              final node = tester.getSemantics(expanded);
              expect(node.flagsCollection.isButton, isTrue);
              expect(node.flagsCollection.isExpanded.toBoolOrNull(), isTrue);
              expect(
                node.getSemanticsData().hasAction(SemanticsAction.tap),
                isTrue,
              );
              expect(
                find.text(locale == 'zh' ? '好友列表' : 'Friends'),
                findsOneWidget,
              );
              expect(
                find.text(locale == 'zh' ? '鱿鱼圈' : 'SplatNet 3'),
                findsOneWidget,
              );
              expect(
                find.text(locale == 'zh' ? '观星' : 'Gear Seed'),
                findsOneWidget,
              );
              await tester.tap(target);
              await tester.pumpAndSettle();
              expect(
                find.text(locale == 'zh' ? '好友列表' : 'Friends'),
                findsNothing,
              );
            }
            expect(tester.takeException(), isNull);
            semantics.dispose();
          }

          await tester.pumpWidget(const SizedBox.shrink());
          transfer.dispose();
          sync.dispose();
          settings.dispose();
        }, variant: TargetPlatformVariant({TargetPlatform.android}));
      }
    }
  }

  testWidgets('decorative arrow centers on the whole account header', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: AndroidAccountExpander(
              identity: SizedBox(width: 80, height: 150, child: Text('Name')),
              details: Text('Status'),
              children: [Text('Tools')],
            ),
          ),
        ),
      ),
    );
    final header = tester.getRect(find.byType(InkWell));
    final arrow = tester.getRect(find.byIcon(Icons.expand_more));
    expect(arrow.center.dy, closeTo(header.center.dy, .1));
    expect(find.byType(IconButton), findsNothing);
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    expect(find.text('Tools'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
