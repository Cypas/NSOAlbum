import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/rust/models.dart';
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
    await tester.tap(find.byKey(const Key('android-sync-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('立即同步'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('已处理 2 / 5 · 已同步 1 · 失败 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('android-page-back')));
    await tester.pumpAndSettle();
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
}
