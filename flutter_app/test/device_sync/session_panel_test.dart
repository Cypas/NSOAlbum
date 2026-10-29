import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/service_contract.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/device_sync/driver.dart' as driver;
import 'package:squid_album/src/rust/device_sync/planner.dart' as plan;
import 'package:squid_album/src/rust/device_sync/read_model.dart' as read;
import 'package:squid_album/src/rust/device_sync/runtime.dart' as runtime;
import 'package:squid_album/src/rust/device_sync/space_budget.dart' as budget;
import 'package:squid_album/src/rust/device_sync/work.dart';
import 'package:squid_album/src/ui/device_sync/session_panel.dart';

void main() {
  testWidgets(
    'live original pinning replaces stale configuration without granting controls',
    (tester) async {
      for (final language in ['zh', 'en']) {
        final session = PanelSession()
          ..confirmed = true
          ..state = endpoint(driver.State.configuring)
          ..liveProgress = read.ProgressView(
            workStage: WorkStage.pinning,
            workActive: true,
            scannedItems: BigInt.from(4),
            totalItems: BigInt.from(12),
          );
        await tester.pumpWidget(
          panelApp(session, language: language, scale: 2),
        );
        expect(
          find.text(
            language == 'zh' ? '正在校验图库原件' : 'Verifying library originals',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            language == 'zh' ? '等待手机选择同步内容' : 'Waiting for phone configuration',
          ),
          findsNothing,
        );
        expect(find.byKey(const Key('device-configure')), findsNothing);
        expect(find.byKey(const Key('device-approve-preview')), findsNothing);
        expect(find.byKey(const Key('device-item-progress')), findsOneWidget);
        expect(session.snapshot?.value?.stage, driver.State.configuring);
        expect(session.configurations, isEmpty);
        expect(tester.takeException(), isNull);
        session.liveProgress = null;
        session.update(endpoint(driver.State.awaitingApproval));
        await tester.pump();
        expect(
          find.textContaining('Verifying library originals'),
          findsNothing,
        );
        expect(find.text('正在校验图库原件'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
  testWidgets(
    'confirmed pairing never asks for the original phone confirmation again',
    (tester) async {
      for (final language in ['zh', 'en']) {
        final session = PanelSession()
          ..state = endpoint(
            driver.State.configuring,
            host: true,
            controller: false,
          );
        await tester.pumpWidget(panelApp(session, language: language));
        expect(find.text('123 456'), findsNothing);
        expect(
          find.text(
            language == 'zh'
                ? '请在手机确认本次连接。'
                : 'Confirm this connection on the phone.',
          ),
          findsNothing,
        );
        expect(
          find.text(
            language == 'zh'
                ? '请在手机选择同步方向、模式和内容。'
                : 'Choose the direction, mode and content on the phone.',
          ),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'detached installed receiver preserves local phase and accessible continuation without reconnect error',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(320, 820);
      tester.view.devicePixelRatio = 1;
      for (final language in ['zh', 'en']) {
        final semantics = tester.ensureSemantics();
        final sample = endpoint(
          driver.State.awaitingExternal,
          source: false,
          localApplyInstalled: true,
          transportDetached: true,
        );
        final session = PanelSession()
          ..transportFailure = read.ReadError.disconnected
          ..state = read.EndpointRead(
            value: sample.value,
            progress: sample.progress,
            tcp: const runtime.TcpView(
              phase: runtime.TcpPhase.closed,
              error: read.ReadError.disconnected,
            ),
          );
        await tester.pumpWidget(
          panelApp(session, language: language, scale: 2),
        );
        expect(
          find.text(language == 'zh' ? '正在安全保存账号' : 'Saving accounts safely'),
          findsOneWidget,
        );
        final notice = find.byKey(const Key('device-local-continuation'));
        expect(
          find.text(
            language == 'zh'
                ? '已传输 0.02 KB / 0.1 KB'
                : 'Transferred 0.02 KB / 0.1 KB',
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('device-transfer-rate')), findsNothing);
        expect(notice, findsOneWidget);
        await tester.ensureVisible(notice);
        expect(
          tester
              .getSemantics(notice)
              .getSemanticsData()
              .flagsCollection
              .isLiveRegion,
          isTrue,
        );
        expect(find.byKey(const Key('device-session-error')), findsNothing);
        expect(tester.takeException(), isNull);
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'finalized receiver cleanup and sender unconfirmed remain different outcomes in both languages',
    (tester) async {
      for (final language in ['zh', 'en']) {
        final session = PanelSession()
          ..cleanup = true
          ..transportFailure = read.ReadError.internal
          ..state = endpoint(
            driver.State.completed,
            source: false,
            localApplyInstalled: true,
            transportDetached: true,
          );
        await tester.pumpWidget(
          panelApp(session, language: language, scale: 2),
        );
        expect(
          find.text(language == 'zh' ? '同步完成' : 'Sync complete'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('device-local-cleanup')), findsOneWidget);
        expect(find.byKey(const Key('device-session-error')), findsNothing);
        session.cleanup = false;
        session.update(
          endpoint(
            driver.State.completedUnconfirmed,
            source: true,
            sourceGrantIssued: true,
            transportDetached: true,
          ),
        );
        await tester.pump();
        expect(
          find.text(
            language == 'zh'
                ? '结果未确认，请在接收设备查看。'
                : 'Result unconfirmed. Check the receiving device.',
          ),
          findsOneWidget,
        );
        expect(
          find.text(language == 'zh' ? '同步完成' : 'Sync complete'),
          findsNothing,
        );
        expect(find.byKey(const Key('device-session-error')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'configuration status directs both endpoints to the phone in both languages',
    (tester) async {
      for (final language in ['zh', 'en']) {
        for (final host in [false, true]) {
          final session = PanelSession()
            ..state = endpoint(
              driver.State.configuring,
              host: host,
              controller: !host,
            );
          await tester.pumpWidget(panelApp(session, language: language));
          expect(
            find.text(
              language == 'zh'
                  ? '等待手机选择同步内容'
                  : 'Waiting for phone configuration',
            ),
            findsOneWidget,
          );
          expect(
            find.textContaining(
              language == 'zh' ? '等待桌面' : 'Waiting for desktop',
            ),
            findsNothing,
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    },
  );

  testWidgets(
    'desktop displays the authenticated matching code without confirmation authority',
    (tester) async {
      for (final language in ['zh', 'en']) {
        final session = PanelSession()
          ..state = endpoint(
            driver.State.pairing,
            pairing: read.PairingStage.awaitingConfirmation,
            host: true,
            controller: false,
          );
        expect(session.snapshot?.value?.confirmationAvailable, isFalse);
        await tester.pumpWidget(panelApp(session, language: language));
        expect(find.text('123 456'), findsOneWidget);
        expect(find.byKey(const Key('device-confirm-pair')), findsNothing);
        expect(
          find.text(
            language == 'zh'
                ? '请在手机确认本次连接。'
                : 'Confirm this connection on the phone.',
          ),
          findsOneWidget,
        );
        expect(session.confirmedLocally, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'temporary action Busy disappears after verified session progress but fatal errors remain',
    (tester) async {
      for (final failure in [
        const DeviceSyncBusy(),
        StateError('synthetic fatal'),
      ]) {
        final session = _FailingConsentSession(failure)
          ..confirmed = true
          ..state = endpoint(driver.State.awaitingAccountConsent);
        await tester.pumpWidget(panelApp(session));
        await tester.ensureVisible(
          find.byKey(const Key('device-allow-accounts')),
        );
        await tester.tap(find.byKey(const Key('device-allow-accounts')));
        await tester.pump();
        expect(find.byKey(const Key('device-session-error')), findsOneWidget);
        session.liveProgress = read.ProgressView(
          workStage: WorkStage.pinning,
          workActive: true,
          scannedItems: BigInt.one,
        );
        session.update(
          endpoint(
            driver.State.awaitingAccountConsent,
            host: true,
            phoneControlled: false,
          ),
        );
        await tester.pump();
        expect(
          find.byKey(const Key('device-session-error')),
          failure is DeviceSyncBusy ? findsNothing : findsOneWidget,
        );
        session.liveProgress = null;
        session.update(endpoint(driver.State.completed));
        await tester.pump();
        expect(
          find.byKey(const Key('device-session-error')),
          failure is DeviceSyncBusy ? findsNothing : findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'preview shows one direction and actual media bytes without receiver budget estimates',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(320, 820);
      tester.view.devicePixelRatio = 1;
      for (final language in ['zh', 'en']) {
        final session = PanelSession()
          ..shown = samePreview
          ..state = endpoint(
            driver.State.awaitingApproval,
            source: false,
            configuration: const read.AgreedConfiguration(
              phoneToDesktop: false,
              mode: plan.SyncMode.overwrite,
              includeAccounts: true,
            ),
          );
        await tester.pumpWidget(
          panelApp(session, language: language, scale: 2),
        );
        expect(find.byKey(const Key('device-sync-direction')), findsOneWidget);
        expect(
          find.text(language == 'zh' ? '需传输 0.1 KB' : 'To transfer: 0.1 KB'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('device-space-details')), findsNothing);
        expect(find.textContaining('80.17 MB'), findsNothing);
        expect(find.textContaining('95.37 MB'), findsNothing);
        expect(
          find.textContaining(language == 'zh' ? '数据库' : 'Database'),
          findsNothing,
        );
        expect(
          find.textContaining(language == 'zh' ? '安全余量' : 'safety margin'),
          findsNothing,
        );
        await tester.ensureVisible(
          find.byKey(const Key('device-approve-preview')),
        );
        expect(tester.takeException(), isNull);
        session.update(
          endpoint(
            driver.State.awaitingAccountConsent,
            source: true,
            host: true,
            controller: false,
          ),
        );
        await tester.pump();
        expect(find.byKey(const Key('device-sync-direction')), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'rapid pairing confirmation queues once and drops it after the session advances',
    (tester) async {
      final started = Completer<void>();
      final finish = Completer<void>();
      final session = _BusyPairingSession(started, finish)
        ..state = endpoint(
          driver.State.pairing,
          pairing: read.PairingStage.awaitingConfirmation,
        );
      await tester.pumpWidget(panelApp(session));

      await tester.tap(find.byKey(const Key('device-confirm-pair')));
      await tester.pump();
      expect(
        find.byKey(const Key('device-confirm-pair-progress')),
        findsOneWidget,
      );
      await started.future;
      await tester.tap(find.byKey(const Key('device-confirm-pair')));
      await tester.tap(find.byKey(const Key('device-confirm-pair')));
      await tester.pump();
      expect(session.confirmCalls, 1);

      session.update(endpoint(driver.State.configuring));
      finish.complete();
      await tester.pumpAndSettle();
      expect(session.confirmCalls, 1);
      expect(session.confirmedLocally, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'rapid preview approval queues once and drops it after the stage changes',
    (tester) async {
      final started = Completer<void>();
      final finish = Completer<void>();
      final session = _BusyApprovalSession(started, finish)
        ..shown = _mergePreview
        ..state = endpoint(
          driver.State.awaitingApproval,
          source: false,
          configuration: const read.AgreedConfiguration(
            phoneToDesktop: false,
            mode: plan.SyncMode.merge,
            includeAccounts: false,
          ),
        );
      await tester.pumpWidget(panelApp(session));
      await tester.ensureVisible(
        find.byKey(const Key('device-approve-preview')),
      );

      await tester.tap(find.byKey(const Key('device-approve-preview')));
      await tester.pump();
      expect(find.byKey(const Key('device-approve-progress')), findsOneWidget);
      await started.future;
      await tester.tap(find.byKey(const Key('device-approve-preview')));
      await tester.tap(find.byKey(const Key('device-approve-preview')));
      await tester.pump();
      expect(session.approvalCalls, 1);

      session.update(
        endpoint(
          driver.State.verifying,
          source: false,
          configuration: const read.AgreedConfiguration(
            phoneToDesktop: false,
            mode: plan.SyncMode.merge,
            includeAccounts: false,
          ),
        ),
      );
      finish.complete();
      // Verifying now exposes an honest indeterminate stage bar, so there is
      // intentionally an active ticker; one frame is enough to observe the
      // queued action being dropped.
      await tester.pump();
      expect(session.approvalCalls, 1);
      expect(session.approvals, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'insufficient receiving space gives localized action without paths',
    (tester) async {
      for (final language in ['zh', 'en']) {
        final session = PanelSession()
          ..failure = read.ReadError.insufficientSpace
          ..state = endpoint(driver.State.failed, source: false);
        await tester.pumpWidget(panelApp(session, language: language));
        expect(
          find.text(
            language == 'zh' ? '接收设备空间不足，请释放空间后重新连接。' : 'The receiving device does not have enough space. Free up space and reconnect.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('F:'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'terminal transport error is not lost behind an empty read error',
    (tester) async {
      final sample = endpoint(driver.State.failed, source: false);
      final session = PanelSession()
        ..state = read.EndpointRead(
          value: sample.value,
          progress: sample.progress,
          tcp: const runtime.TcpView(
            phase: runtime.TcpPhase.closed,
            error: read.ReadError.insufficientSpace,
          ),
        );
      await tester.pumpWidget(panelApp(session));
      expect(find.textContaining('does not have enough space'), findsOneWidget);
    },
  );
  testWidgets(
    'transfer progress stays mounted and retains the last sample during a transient read gap',
    (tester) async {
      final session = PanelSession()
        ..state = endpoint(
          driver.State.transferring,
          transferProgress: read.ProgressView(
            workStage: WorkStage.idle,
            workActive: false,
            scannedItems: BigInt.zero,
            transferredBytes: BigInt.from(10),
            transferTotalBytes: BigInt.from(100),
            transferBytesPerSecond: BigInt.from(20),
          ),
        );
      await tester.pumpWidget(panelApp(session));
      final progressState = tester.state(
        find.byKey(const Key('device-transfer-progress-section')),
      );
      expect(find.byKey(const Key('device-byte-progress')), findsOneWidget);
      expect(find.text('Transferred 0.01 KB / 0.1 KB'), findsOneWidget);

      session.update(
        endpoint(
          driver.State.transferring,
          transferProgress: read.ProgressView(
            workStage: WorkStage.idle,
            workActive: false,
            scannedItems: BigInt.zero,
            transferredBytes: null,
            transferTotalBytes: BigInt.from(100),
            transferBytesPerSecond: null,
          ),
        ),
      );
      await tester.pump();

      expect(
        identical(
          progressState,
          tester.state(
            find.byKey(const Key('device-transfer-progress-section')),
          ),
        ),
        isTrue,
      );
      expect(find.byKey(const Key('device-byte-progress')), findsOneWidget);
      expect(find.text('Transferred 0.01 KB / 0.1 KB'), findsOneWidget);

      session.update(
        endpoint(
          driver.State.transferring,
          transferProgress: read.ProgressView(
            workStage: WorkStage.idle,
            workActive: false,
            scannedItems: BigInt.zero,
            transferredBytes: BigInt.from(20),
            transferTotalBytes: BigInt.from(100),
            transferBytesPerSecond: BigInt.from(24),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Transferred 0.02 KB / 0.1 KB'), findsOneWidget);
      expect(find.text('Current speed: 0.02 KB/s'), findsOneWidget);
    },
  );
  testWidgets(
    'stage progress remains visible while native work counters are temporarily idle',
    (tester) async {
      final semantics = tester.ensureSemantics();
      const stages = [
        driver.State.scanning,
        driver.State.comparing,
        driver.State.verifying,
        driver.State.applying,
      ];
      for (final language in ['zh', 'en']) {
        for (final stage in stages) {
          final session = PanelSession()
            ..state = endpoint(
              stage,
              transferProgress: read.ProgressView(
                workStage: WorkStage.idle,
                workActive: false,
                scannedItems: BigInt.zero,
              ),
            );
          await tester.pumpWidget(panelApp(session, language: language));

          final progress = find.byKey(const Key('device-stage-progress'));
          expect(progress, findsOneWidget);
          expect(
            find.byKey(const Key('device-stage-progress-bar')),
            findsOneWidget,
          );
          expect(find.byKey(const Key('device-item-progress')), findsNothing);
          expect(
            tester.getSemantics(progress).label,
            language == 'zh'
                ? switch (stage) {
                    driver.State.scanning => '正在扫描图库，正在处理',
                    driver.State.comparing => '正在比较图库，正在处理',
                    driver.State.verifying => '正在校验，正在处理',
                    driver.State.applying => '正在应用更改，正在处理',
                    _ => '',
                  }
                : switch (stage) {
                    driver.State.scanning => 'Scanning library, in progress',
                    driver.State.comparing =>
                      'Comparing libraries, in progress',
                    driver.State.verifying => 'Verifying, in progress',
                    driver.State.applying => 'Applying changes, in progress',
                    _ => '',
                  },
          );
          expect(
            tester.getSemantics(progress).flagsCollection.isLiveRegion,
            isTrue,
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
      semantics.dispose();
    },
  );
  testWidgets(
    'background checkpoints do not move the transfer bar or rebuild the session heading',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      for (final host in [false, true]) {
        for (final language in ['zh', 'en']) {
          final session = PanelSession()
            ..state = endpoint(
              driver.State.transferring,
              host: host,
              controller: !host,
              transferProgress: read.ProgressView(
                workStage: WorkStage.idle,
                workActive: false,
                scannedItems: BigInt.zero,
                transferredBytes: BigInt.from(10),
                transferTotalBytes: BigInt.from(100),
                transferBytesPerSecond: BigInt.from(20),
              ),
            );
          await tester.pumpWidget(
            panelApp(session, language: language, scale: 2),
          );
          final bar = find.byKey(const Key('device-byte-progress'));
          final rate = find.byKey(const Key('device-transfer-rate'));
          final heading = find.text(language == 'zh' ? '正在传输' : 'Transferring');
          final headingWidget = tester.widget(heading);
          final barState = tester.state(bar);
          final barPosition = tester.getTopLeft(bar);
          final ratePosition = tester.getTopLeft(rate);
          Widget? previousRateWidget;
          for (final active in [true, false, true, false]) {
            session.update(
              endpoint(
                driver.State.transferring,
                host: host,
                controller: !host,
                transferProgress: read.ProgressView(
                  workStage: WorkStage.pinning,
                  workActive: active,
                  scannedItems: BigInt.one,
                  transferredBytes: BigInt.from(20),
                  transferTotalBytes: BigInt.from(100),
                  transferBytesPerSecond: BigInt.from(24),
                ),
              ),
            );
            await tester.pump();
            expect(find.byType(LinearProgressIndicator), findsOneWidget);
            expect(tester.getTopLeft(bar), barPosition);
            expect(tester.getTopLeft(rate), ratePosition);
            expect(identical(tester.state(bar), barState), isTrue);
            expect(identical(tester.widget(heading), headingWidget), isTrue);
            if (previousRateWidget != null) {
              expect(
                identical(tester.widget(rate), previousRateWidget),
                isTrue,
              );
            }
            previousRateWidget = tester.widget(rate);
            expect(tester.takeException(), isNull);
          }
          // Identical native samples do not rebuild even the numeric region.
          final rateWidget = tester.widget(rate);
          session.update(session.state);
          await tester.pump();
          expect(identical(tester.widget(rate), rateWidget), isTrue);
          session.update(endpoint(driver.State.cancelled));
          await tester.pump();
          expect(bar, findsNothing);
          expect(rate, findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    },
  );
  testWidgets(
    'closed disconnected TCP cannot contradict a confirmed durable completion',
    (tester) async {
      for (final source in [false, true]) {
        for (final stage in [
          driver.State.completed,
          driver.State.completedUnconfirmed,
          driver.State.failed,
        ]) {
          final sample = endpoint(stage, source: source);
          final session = PanelSession()
            ..state = read.EndpointRead(
              value: sample.value,
              progress: sample.progress,
              tcp: const runtime.TcpView(
                phase: runtime.TcpPhase.closed,
                error: read.ReadError.disconnected,
              ),
            );
          await tester.pumpWidget(panelApp(session));
          expect(
            find.byKey(const Key('device-session-error')),
            stage == driver.State.completed ? findsNothing : findsOneWidget,
          );
          if (stage == driver.State.completed) {
            expect(find.text('Sync complete'), findsOneWidget);
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    },
  );

  testWidgets(
    'phone confirms pairing and selects explicit modes without desktop input',
    (tester) async {
      final session = PanelSession()
        ..state = endpoint(
          driver.State.pairing,
          pairing: read.PairingStage.awaitingConfirmation,
        );
      await tester.pumpWidget(panelApp(session));
      expect(find.text('123 456'), findsOneWidget);
      expect(
        find.textContaining('Phone with a long display name'),
        findsOneWidget,
      );
      expect(session.confirmedLocally, isFalse);
      expect(find.byKey(const Key('device-configure')), findsNothing);
      await tester.tap(find.byKey(const Key('device-confirm-pair')));
      await tester.pump();
      expect(session.confirmedLocally, isTrue);
      expect(session.configurations, isEmpty);
      session.update(endpoint(driver.State.configuring));
      await tester.pump();
      expect(find.byType(SwitchListTile), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('device-mode-merge')));
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const Key('device-mode-merge')))
            .selected,
        isTrue,
      );
      await tester.ensureVisible(find.byKey(const Key('device-configure')));
      await tester.tap(find.byKey(const Key('device-configure')));
      await tester.pump();
      expect(session.configurations, [
        (phoneToDesktop: false, overwrite: false, includeAccounts: false),
      ]);
      expect(session.consents, isEmpty);
    },
  );

  testWidgets(
    'receiver approval consumes the displayed preview only on click',
    (tester) async {
      final session = PanelSession()
        ..state = endpoint(driver.State.awaitingApproval, source: false);
      await tester.pumpWidget(panelApp(session));
      expect(session.approvals, isEmpty);
      await tester.tap(find.byKey(const Key('device-review-preview')));
      await tester.pump();
      expect(find.textContaining('Added 3'), findsWidgets);
      expect(session.approvals, isEmpty);
      await tester.ensureVisible(
        find.byKey(const Key('device-approve-preview')),
      );
      await tester.tap(find.byKey(const Key('device-approve-preview')));
      await tester.pump();
      expect(session.approvals, isEmpty);
      expect(find.byKey(const Key('device-confirm-overwrite')), findsOneWidget);
      await tester.tap(find.byKey(const Key('device-confirm-overwrite')));
      await tester.pump();
      expect(session.approvals, [samePreview]);
    },
  );

  testWidgets('account request needs a separate local allow or library-only', (
    tester,
  ) async {
    for (final accepted in [false, true]) {
      final session = PanelSession()
        ..state = endpoint(
          driver.State.awaitingAccountConsent,
          host: true,
          phoneControlled: false,
        )
        ..confirmed = true;
      await tester.pumpWidget(panelApp(session));
      expect(session.consents, isEmpty);
      await tester.ensureVisible(
        find.byKey(
          Key(accepted ? 'device-allow-accounts' : 'device-no-accounts'),
        ),
      );
      await tester.tap(
        find.byKey(
          Key(accepted ? 'device-allow-accounts' : 'device-no-accounts'),
        ),
      );
      await tester.pump();
      expect(session.consents, [accepted]);
      expect(session.approvals, isEmpty);
    }
  });

  testWidgets(
    'phone account selection authorizes this sync without a second prompt',
    (tester) async {
      final session = PanelSession()
        ..confirmed = true
        ..state = endpoint(
          driver.State.awaitingAccountConsent,
          phoneControlled: true,
          controller: true,
          configuration: const read.AgreedConfiguration(
            phoneToDesktop: false,
            mode: plan.SyncMode.merge,
            includeAccounts: true,
          ),
        );
      session.proposedConfiguration = const DeviceSyncProposal(
        phoneToDesktop: false,
        mode: plan.SyncMode.merge,
        includeAccounts: true,
      );
      await tester.pumpWidget(panelApp(session));
      await tester.pumpAndSettle();

      expect(session.consents, [true]);
      expect(find.byKey(const Key('device-allow-accounts')), findsNothing);
      expect(find.byKey(const Key('device-no-accounts')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop delegates pairing, configuration and preview to phone', (
    tester,
  ) async {
    final session = PanelSession();
    await tester.pumpWidget(panelApp(session));
    for (final stage in [
      driver.State.pairing,
      driver.State.configuring,
      driver.State.awaitingAccountConsent,
      driver.State.awaitingApproval,
    ]) {
      session.update(
        endpoint(
          stage,
          host: true,
          controller: false,
          source: false,
          pairing: stage == driver.State.pairing
              ? read.PairingStage.awaitingConfirmation
              : read.PairingStage.confirmed,
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('device-confirm-pair')), findsNothing);
      expect(find.byKey(const Key('device-configure')), findsNothing);
      expect(find.byKey(const Key('device-allow-accounts')), findsNothing);
      expect(find.byKey(const Key('device-approve-preview')), findsNothing);
    }
    expect(session.configurations, isEmpty);
    expect(session.approvals, isEmpty);
    expect(session.consents, isEmpty);
  });

  testWidgets('phone source can review the receiving desktop preview', (
    tester,
  ) async {
    final session = PanelSession()
      ..confirmed = true
      ..state = endpoint(driver.State.awaitingApproval, source: true);
    await tester.pumpWidget(panelApp(session));
    await tester.tap(find.byKey(const Key('device-review-preview')));
    await tester.pump();
    expect(find.text('To transfer: 0.1 KB'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('device-approve-preview')));
    expect(find.byKey(const Key('device-approve-preview')), findsOneWidget);
    expect(session.approvals, isEmpty);
  });

  testWidgets(
    'unknown total remains localized but an initial transfer rate is zero',
    (tester) async {
      for (final language in ['zh', 'en']) {
        final session = PanelSession()
          ..state = endpoint(
            driver.State.transferring,
            transferProgress: read.ProgressView(
              workStage: WorkStage.idle,
              workActive: false,
              scannedItems: BigInt.zero,
              transferredBytes: BigInt.zero,
            ),
          );
        await tester.pumpWidget(panelApp(session, language: language));
        expect(
          find.text(
            language == 'zh' ? '已传输 0 KB / 未知' : 'Transferred 0 KB / Unknown',
          ),
          findsOneWidget,
        );
        expect(
          find.text(language == 'zh' ? '当前速度：0 KB/s' : 'Current speed: 0 KB/s'),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets('real throughput appears on either role and not after transfer', (
    tester,
  ) async {
    for (final host in [false, true]) {
      final session = PanelSession()
        ..state = endpoint(
          driver.State.transferring,
          host: host,
          controller: !host,
          source: host,
          transferProgress: read.ProgressView(
            workStage: WorkStage.idle,
            workActive: false,
            scannedItems: BigInt.zero,
            transferredBytes: BigInt.from(1048576),
            transferTotalBytes: BigInt.from(4194304),
            transferBytesPerSecond: BigInt.from(1572864),
          ),
        );
      await tester.pumpWidget(panelApp(session));
      expect(find.textContaining('1 MB / 4 MB'), findsOneWidget);
      expect(find.textContaining('1.5 MB/s'), findsOneWidget);
      session.update(endpoint(driver.State.applying));
      await tester.pump();
      expect(find.byKey(const Key('device-transfer-rate')), findsNothing);
      session.update(endpoint(driver.State.completed));
      await tester.pump();
      expect(find.byKey(const Key('device-byte-progress')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('initial and idle transfer speed is zero on either role', (
    tester,
  ) async {
    for (final host in [false, true]) {
      final session = PanelSession()
        ..state = endpoint(
          driver.State.transferring,
          host: host,
          source: host,
          transferProgress: read.ProgressView(
            workStage: WorkStage.idle,
            workActive: false,
            scannedItems: BigInt.zero,
            transferredBytes: BigInt.zero,
            transferTotalBytes: BigInt.from(4194304),
          ),
        );
      await tester.pumpWidget(panelApp(session));
      expect(find.textContaining('0 KB/s'), findsOneWidget);
      final original = tester.element(
        find.byKey(const Key('device-byte-progress')),
      );
      session.update(session.state);
      await tester.pump();
      expect(
        tester.element(find.byKey(const Key('device-byte-progress'))),
        same(original),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('progress uses bytes and terminal states never imply receipt', (
    tester,
  ) async {
    final session = PanelSession()
      ..state = endpoint(driver.State.transferring, source: false);
    await tester.pumpWidget(panelApp(session));
    final progress = tester.widget<LinearProgressIndicator>(
      find.byKey(const Key('device-byte-progress')),
    );
    expect(progress.value, .25);
    expect(find.textContaining('0.02 KB / 0.1 KB'), findsOneWidget);
    session.update(endpoint(driver.State.completedUnconfirmed, source: false));
    await tester.pump();
    expect(
      find.text('Result unconfirmed. Check the receiving device.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('device-approve-preview')), findsNothing);
    session.update(endpoint(driver.State.recoveryPending, source: false));
    await tester.pump();
    expect(find.text('Recovery required'), findsOneWidget);
  });

  testWidgets(
    'unconfirmed outcome makes no completion claim in either language',
    (tester) async {
      for (final language in ['zh', 'en']) {
        final session = PanelSession()
          ..state = endpoint(driver.State.completedUnconfirmed, source: true);
        await tester.pumpWidget(panelApp(session, language: language));
        expect(
          find.text(
            language == 'zh'
                ? '结果未确认，请在接收设备查看。'
                : 'Result unconfirmed. Check the receiving device.',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining(language == 'zh' ? '本机已完成' : 'Completed;'),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
}

Widget panelApp(
  DeviceSyncSessionController session, {
  String language = 'en',
  Brightness brightness = Brightness.light,
  double scale = 1,
}) => MaterialApp(
  locale: Locale(language),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  theme: ThemeData(brightness: brightness),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: DeviceSyncSessionPanel(
          key: ObjectKey(session),
          session: session,
        ),
      ),
    ),
  ),
);

final counts = read.ChangeCounts(
  added: BigInt.from(3),
  replaced: BigInt.one,
  removed: BigInt.from(2),
  kept: BigInt.from(4),
);
final samePreview = DeviceSyncPreviewView(
  library: read.PreviewSummary(
    binding: 'private-binding',
    mode: plan.SyncMode.overwrite,
    media: counts,
    albums: counts,
    space: plan.SpaceEstimate(
      newStagingBytes: BigInt.from(100),
      reusableOriginalBytes: BigInt.zero,
      backupOriginalBytes: BigInt.from(200),
      backupBytesIfCopied: BigInt.from(200),
      conservativeContentBytes: BigInt.from(300),
      excludesMetadataAndFilesystemOverhead: true,
    ),
    conflicts: read.ConflictCounts(
      unknownRevision: BigInt.one,
      equalRevision: BigInt.one,
      clockSkew: BigInt.one,
    ),
    receiverBudget: budget.ReceiverBudgetView(
      includesMetadata: true,
      includesAllocationEstimate: true,
      volumes: [
        budget.VolumeBudgetView(
          roles: [
            budget.StorageRole.staging,
            budget.StorageRole.originals,
            budget.StorageRole.database,
          ],
          additionalBytes: BigInt.from(16958640),
          safetyMarginBytes: BigInt.from(67108864),
          requiredBytes: BigInt.from(84067504),
          availableBytes: BigInt.from(99999999),
        ),
      ],
    ),
  ),
);
final _mergePreview = DeviceSyncPreviewView(
  library: read.PreviewSummary(
    binding: 'merge-preview',
    mode: plan.SyncMode.merge,
    media: counts,
    albums: counts,
    space: plan.SpaceEstimate(
      newStagingBytes: BigInt.from(100),
      reusableOriginalBytes: BigInt.zero,
      backupOriginalBytes: BigInt.zero,
      backupBytesIfCopied: BigInt.zero,
      conservativeContentBytes: BigInt.from(100),
      excludesMetadataAndFilesystemOverhead: true,
    ),
    conflicts: read.ConflictCounts(
      unknownRevision: BigInt.zero,
      equalRevision: BigInt.zero,
      clockSkew: BigInt.zero,
    ),
  ),
);
final progress = read.ProgressView(
  workStage: WorkStage.idle,
  workActive: false,
  scannedItems: BigInt.from(2),
  transferredBytes: BigInt.from(25),
  transferTotalBytes: BigInt.from(100),
);
read.EndpointRead endpoint(
  driver.State stage, {
  read.PairingStage pairing = read.PairingStage.confirmed,
  bool? source,
  String peerName = 'Phone with a long display name',
  bool cleanupPending = false,
  bool host = false,
  bool controller = true,
  bool phoneControlled = true,
  bool previewApproved = false,
  bool accountsConsentAuthorized = false,
  bool localApplyInstalled = false,
  bool sourceGrantIssued = false,
  bool transportDetached = false,
  read.ProgressView? transferProgress,
  read.AgreedConfiguration? configuration,
}) => read.EndpointRead(
  progress: transferProgress ?? progress,
  value: read.EndpointView(
    pairing: pairing,
    confirmationAvailable:
        pairing == read.PairingStage.awaitingConfirmation &&
        (!phoneControlled || controller),
    peerName: peerName,
    transport: read.TransportKind.tcp,
    host: host,
    controller: controller,
    phoneControlled: phoneControlled,
    previewApproved: previewApproved,
    accountsConsentAuthorized: accountsConsentAuthorized,
    source: source,
    configuration: configuration,
    stage: stage,
    terminal: [
      driver.State.completed,
      driver.State.completedUnconfirmed,
      driver.State.cancelled,
      driver.State.failed,
      driver.State.recoveryPending,
    ].contains(stage),
    cleanupPending: cleanupPending,
    localApplyInstalled: localApplyInstalled,
    sourceGrantIssued: sourceGrantIssued,
    transportDetached: transportDetached,
    progress: transferProgress ?? progress,
  ),
);

class PanelSession extends DeviceSyncSessionController {
  read.ProgressView? liveProgress;
  @override
  read.ProgressView? get presentationProgress =>
      liveProgress ?? snapshot?.progress;
  read.EndpointRead state = endpoint(driver.State.configuring);
  bool confirmed = false;
  final configurations =
      <({bool phoneToDesktop, bool overwrite, bool includeAccounts})>[];
  final consents = <bool>[];
  final approvals = <DeviceSyncPreviewView>[];
  DeviceSyncPreviewView? shown;
  bool retired = false;
  bool released = false;
  Future<void>? closeWait;
  Object? closeFailure;
  read.ReadError? failure;
  read.ReadError? transportFailure;
  bool cleanup = false;
  Future<void>? _closing;
  void update(read.EndpointRead value) {
    state = value;
    notifyListeners();
  }

  @override
  bool get closed => retired;
  @override
  bool get settled => released;
  @override
  bool get busy => false;
  @override
  bool get confirmedLocally => confirmed;
  @override
  bool get accountsAuthorized => consents.lastOrNull == true;
  @override
  String? get invitation => null;
  @override
  String? get confirmationCode => '123 456';
  @override
  read.EndpointRead? get snapshot => state;
  @override
  DeviceSyncProposal? proposedConfiguration = const DeviceSyncProposal(
    phoneToDesktop: false,
    mode: plan.SyncMode.merge,
    includeAccounts: false,
  );
  @override
  DeviceSyncPreviewView? get preview => shown;
  @override
  read.ReadError? get issue => failure;
  @override
  read.ReadError? get transportIssue => transportFailure;
  @override
  bool get localCleanupPending => cleanup;
  @override
  Future<read.EndpointRead> refresh() async => state;
  @override
  Future<void> confirmPairing() async {
    confirmed = true;
    notifyListeners();
  }

  @override
  Future<void> configure({
    required bool phoneToDesktop,
    required bool overwrite,
    bool includeAccounts = false,
  }) async {
    configurations.add((
      phoneToDesktop: phoneToDesktop,
      overwrite: overwrite,
      includeAccounts: includeAccounts,
    ));
  }

  @override
  Future<void> consentAccounts({required bool accepted}) async =>
      consents.add(accepted);
  @override
  Future<DeviceSyncPreviewView> refreshPreview() async => shown = samePreview;
  @override
  Future<void> approvePreview(DeviceSyncPreviewView shown) async =>
      approvals.add(shown);
  @override
  Future<read.ConflictPageRead> conflicts(
    DeviceSyncPreviewView shown, {
    String? cursor,
  }) async => const read.ConflictPageRead(
    value: read.ConflictPage(items: [], next: null),
  );
  @override
  Future<List<DeviceUsbStorageChoice>> usbChoices() async => [];
  @override
  Future<void> selectUsb(DeviceUsbStorageChoice choice) async {}
  @override
  Future<void> close() => _closing ??= () async {
    retired = true;
    await closeWait;
    released = true;
    if (closeFailure case final failure?) throw failure;
  }();
}

class _FailingConsentSession extends PanelSession {
  _FailingConsentSession(this.failureToThrow);
  final Object failureToThrow;
  @override
  Future<void> consentAccounts({required bool accepted}) async =>
      throw failureToThrow;
}

class _BusyPairingSession extends PanelSession {
  _BusyPairingSession(this.started, this.finish);
  final Completer<void> started, finish;
  int confirmCalls = 0;
  @override
  bool get busy => confirmCalls > 0 && !finish.isCompleted;
  @override
  Future<void> confirmPairing() async {
    confirmCalls++;
    if (confirmCalls == 1) {
      started.complete();
      await finish.future;
    }
    if (snapshot?.value?.pairing != read.PairingStage.awaitingConfirmation) {
      return;
    }
    confirmed = true;
    notifyListeners();
  }
}

class _BusyApprovalSession extends PanelSession {
  _BusyApprovalSession(this.started, this.finish);
  final Completer<void> started, finish;
  int approvalCalls = 0;
  @override
  bool get busy => approvalCalls > 0 && !finish.isCompleted;
  @override
  Future<void> approvePreview(DeviceSyncPreviewView shown) async {
    approvalCalls++;
    if (approvalCalls == 1) {
      started.complete();
      await finish.future;
    }
    if (snapshot?.value?.stage != driver.State.awaitingApproval) return;
    await super.approvePreview(shown);
  }
}
