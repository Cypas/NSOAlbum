import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/rust/device_sync/driver.dart' as driver;
import 'package:squid_album/src/rust/device_sync/planner.dart' as plan;
import 'package:squid_album/src/rust/device_sync/read_model.dart' as read;
import 'package:squid_album/src/rust/device_sync/work.dart';

import 'session_panel_test.dart'
    show PanelSession, endpoint, panelApp, samePreview;

void main() {
  testWidgets('session stage light agrees with its accessible status text', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final cases = [
      (
        driver.State.pairing,
        '等待设备连接与确认',
        'Waiting for connection and confirmation',
        'neutral',
      ),
      (
        driver.State.configuring,
        '等待手机选择同步内容',
        'Waiting for phone configuration',
        'neutral',
      ),
      (driver.State.scanning, '正在扫描图库', 'Scanning library', 'active'),
      (driver.State.comparing, '正在比较图库', 'Comparing libraries', 'active'),
      (
        driver.State.awaitingApproval,
        '等待手机确认预览',
        'Waiting for preview confirmation on the phone',
        'neutral',
      ),
      (
        driver.State.awaitingAccountConsent,
        '等待手机授权账号同步',
        'Waiting for account consent on the phone',
        'neutral',
      ),
      (
        driver.State.awaitingAccountFinal,
        '正在准备账号提交',
        'Preparing account commit',
        'active',
      ),
      (
        driver.State.awaitingTargetAccountFinal,
        '正在准备账号提交',
        'Preparing account commit',
        'active',
      ),
      (
        driver.State.awaitingExternal,
        '正在安全保存账号',
        'Saving accounts safely',
        'active',
      ),
      (driver.State.transferring, '正在传输', 'Transferring', 'active'),
      (driver.State.verifying, '正在校验', 'Verifying', 'active'),
      (driver.State.applying, '正在应用更改', 'Applying changes', 'active'),
      (driver.State.completed, '同步完成', 'Sync complete', 'success'),
      (
        driver.State.completedUnconfirmed,
        '结果未确认，请在接收设备查看。',
        'Result unconfirmed. Check the receiving device.',
        'warning',
      ),
      (driver.State.cancelled, '同步已取消', 'Sync cancelled', 'neutral'),
      (driver.State.failed, '同步未完成', 'Sync did not complete', 'failure'),
      (driver.State.recoveryPending, '需要恢复数据', 'Recovery required', 'failure'),
    ];
    for (final brightness in Brightness.values) {
      final dark = brightness == Brightness.dark;
      final colors = {
        'neutral': dark ? Colors.grey.shade400 : Colors.grey.shade600,
        'active': dark ? Colors.blue.shade400 : Colors.blue.shade700,
        'success': dark ? Colors.green.shade400 : Colors.green.shade700,
        'warning': dark ? Colors.amber.shade400 : Colors.amber.shade800,
        'failure': dark ? Colors.red.shade400 : Colors.red.shade700,
      };
      for (final language in ['zh', 'en']) {
        final session = PanelSession();
        for (final (stage, zh, en, tone) in cases) {
          session.update(endpoint(stage, controller: false));
          await tester.pumpWidget(
            panelApp(session, language: language, brightness: brightness),
          );
          final label = language == 'zh' ? zh : en;
          final status = find.byKey(const Key('device-sync-status'));
          expect(
            status,
            findsOneWidget,
            reason: '$stage/$language/$brightness',
          );
          expect(find.text(label), findsOneWidget);
          final dot = find.byKey(const Key('device-sync-status-dot'));
          expect(tester.getSize(dot), const Size(8, 8));
          final decoration =
              tester.widget<Container>(dot).decoration! as BoxDecoration;
          expect(decoration.shape, BoxShape.circle);
          expect(decoration.color, colors[tone]);
          final node = tester.getSemantics(status);
          expect(node.label, label);
          expect(
            node.childrenCount,
            0,
            reason: 'Decorative light must not be read twice',
          );
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
    semantics.dispose();
  });

  testWidgets('live original verification overrides a waiting light', (
    tester,
  ) async {
    final session = PanelSession()
      ..state = endpoint(driver.State.configuring)
      ..liveProgress = read.ProgressView(
        workStage: WorkStage.pinning,
        workActive: true,
        scannedItems: BigInt.one,
      );
    await tester.pumpWidget(panelApp(session));
    expect(find.text('Verifying library originals'), findsOneWidget);
    final dot = find.byKey(const Key('device-sync-status-dot'));
    expect(
      (tester.widget<Container>(dot).decoration! as BoxDecoration).color,
      Colors.blue.shade700,
    );
    session.liveProgress = null;
    session.update(endpoint(driver.State.awaitingApproval));
    await tester.pump();
    expect(find.text('Preview changes'), findsOneWidget);
    expect(
      (tester.widget<Container>(dot).decoration! as BoxDecoration).color,
      Colors.grey.shade600,
    );
  });

  testWidgets(
    'configured direction shows the correct source and target icons',
    (tester) async {
      final semantics = tester.ensureSemantics();
      for (final language in ['zh', 'en']) {
        for (final phoneToDesktop in [false, true]) {
          final session = PanelSession()
            ..shown = samePreview
            ..state = endpoint(
              driver.State.awaitingApproval,
              source: false,
              configuration: read.AgreedConfiguration(
                phoneToDesktop: phoneToDesktop,
                mode: plan.SyncMode.merge,
                includeAccounts: false,
              ),
            );
          await tester.pumpWidget(panelApp(session, language: language));
          final direction = find.byKey(const Key('device-sync-direction'));
          expect(direction, findsOneWidget);
          final source = find.descendant(
            of: direction,
            matching: find.byKey(const Key('device-direction-source')),
          );
          final target = find.descendant(
            of: direction,
            matching: find.byKey(const Key('device-direction-target')),
          );
          expect(
            find.descendant(
              of: source,
              matching: find.byIcon(
                phoneToDesktop ? Icons.smartphone : Icons.desktop_windows,
              ),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: target,
              matching: find.byIcon(
                phoneToDesktop ? Icons.desktop_windows : Icons.smartphone,
              ),
            ),
            findsOneWidget,
          );
          final desktop = language == 'zh' ? '桌面' : 'Desktop';
          final phone = language == 'zh' ? '手机' : 'Phone';
          final label = phoneToDesktop
              ? '$phone → $desktop'
              : '$desktop → $phone';
          expect(tester.getSemantics(direction).label, label);
          expect(tester.getSemantics(direction).childrenCount, 0);
          expect(
            tester.getTopLeft(source).dx,
            lessThan(tester.getTopLeft(target).dx),
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
      semantics.dispose();
    },
  );

  testWidgets(
    'transfer samples keep light, direction and progress elements mounted',
    (tester) async {
      const config = read.AgreedConfiguration(
        phoneToDesktop: false,
        mode: plan.SyncMode.merge,
        includeAccounts: false,
      );
      final session = PanelSession()
        ..state = endpoint(driver.State.transferring, configuration: config);
      await tester.pumpWidget(panelApp(session, scale: 2));
      final keys = [
        'device-sync-status',
        'device-sync-status-dot',
        'device-byte-progress',
        'device-transfer-rate',
      ];
      final elements = {
        for (final key in keys) key: tester.element(find.byKey(Key(key))),
      };
      final initialDot = tester.widget(
        find.byKey(const Key('device-sync-status-dot')),
      );
      for (var sample = 1; sample <= 5; sample++) {
        session.update(
          endpoint(
            driver.State.transferring,
            configuration: config,
            transferProgress: read.ProgressView(
              workStage: WorkStage.idle,
              workActive: false,
              scannedItems: BigInt.zero,
              transferredBytes: BigInt.from(sample * 1024),
              transferTotalBytes: BigInt.from(10240),
              transferBytesPerSecond: BigInt.from(sample * 1024),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        for (final key in keys) {
          expect(tester.element(find.byKey(Key(key))), same(elements[key]));
        }
        expect(
          tester.widget(find.byKey(const Key('device-sync-status-dot'))),
          same(initialDot),
        );
        expect(find.text('Current speed: $sample KB/s'), findsOneWidget);
      }
      session.update(endpoint(driver.State.completed, configuration: config));
      await tester.pump();
      expect(
        tester.element(find.byKey(const Key('device-sync-status-dot'))),
        same(elements['device-sync-status-dot']),
      );
      expect(find.byKey(const Key('device-byte-progress')), findsNothing);
      expect(find.text('Sync complete'), findsOneWidget);
    },
  );
}
