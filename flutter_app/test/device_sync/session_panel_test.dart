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
    'receiver budget is complete and source only promises a local check',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(320, 820);
      tester.view.devicePixelRatio = 1;
      for (final language in ['zh', 'en']) {
        final session = PanelSession()
          ..shown = samePreview
          ..state = endpoint(driver.State.awaitingApproval, source: false);
        await tester.pumpWidget(
          panelApp(session, language: language, scale: 2),
        );
        expect(find.textContaining('80.17 MB'), findsOneWidget);
        expect(find.textContaining('95.37 MB'), findsOneWidget);
        expect(
          find.textContaining(language == 'zh' ? '数据库' : 'Database'),
          findsOneWidget,
        );
        expect(
          find.textContaining(language == 'zh' ? '安全余量' : 'safety margin'),
          findsOneWidget,
        );
        await tester.ensureVisible(
          find.byKey(const Key('device-approve-preview')),
        );
        expect(tester.takeException(), isNull);
        session.update(
          endpoint(
            driver.State.awaitingApproval,
            source: true,
            host: true,
            controller: false,
          ),
        );
        await tester.pump();
        expect(find.textContaining('80.17 MB'), findsNothing);
        expect(
          find.textContaining(
            language == 'zh' ? '接收设备会核对空间' : 'receiving device will check',
          ),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
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
        ..state = endpoint(driver.State.awaitingAccountConsent)
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
    expect(find.textContaining('95.37 MB'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('device-approve-preview')));
    expect(find.byKey(const Key('device-approve-preview')), findsOneWidget);
    expect(session.approvals, isEmpty);
  });

  testWidgets(
    'unknown transfer total and rate are localized instead of a dash',
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
            language == 'zh' ? '已传输 0 B / 未知' : 'Transferred 0 B / Unknown',
          ),
          findsOneWidget,
        );
        expect(
          find.text(language == 'zh' ? '当前速度：未知' : 'Current speed: Unknown'),
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
    expect(find.textContaining('25 B / 100 B'), findsOneWidget);
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

  testWidgets(
    'large-text session controls and long device names remain scrollable',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final width in [320.0, 360.0, 412.0]) {
        tester.view.physicalSize = Size(width, 820);
        tester.view.devicePixelRatio = 1;
        for (final language in ['zh', 'en']) {
          for (final brightness in Brightness.values) {
            final session = PanelSession()
              ..confirmed = true
              ..state = endpoint(
                driver.State.configuring,
                peerName: '合成设备名 Synthetic very long device name ' * 6,
              );
            await tester.pumpWidget(
              panelApp(
                session,
                language: language,
                brightness: brightness,
                scale: 2,
              ),
            );
            await tester.pump();
            await tester.ensureVisible(
              find.byKey(const Key('device-configure')),
            );
            await tester.pump();
            expect(tester.takeException(), isNull);
            session.shown = samePreview;
            session.update(
              endpoint(driver.State.awaitingApproval, source: false),
            );
            await tester.pump();
            await tester.ensureVisible(
              find.byKey(const Key('device-approve-preview')),
            );
            await tester.pump();
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          }
        }
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
    progress: transferProgress ?? progress,
  ),
);

class PanelSession extends DeviceSyncSessionController {
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
  DeviceSyncProposal? get proposedConfiguration => const DeviceSyncProposal(
    phoneToDesktop: false,
    mode: plan.SyncMode.merge,
    includeAccounts: true,
  );
  @override
  DeviceSyncPreviewView? get preview => shown;
  @override
  read.ReadError? get issue => failure;
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
