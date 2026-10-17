import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/backend/device_sync/account_gate.dart';
import 'package:squid_album/src/backend/device_sync/startup_lifecycle.dart';
import 'package:squid_album/src/ui/desktop_window_drag_area.dart';
import 'package:squid_album/src/ui/device_sync/device_sync_page.dart';
import 'package:squid_album/src/ui/device_sync/entry.dart';

import '../home_shell_test.dart' show FakeBackend;
import 'device_sync_page_test.dart' show pageApp;

void main() {
  testWidgets('desktop transfer opens independent protected sync page', (
    tester,
  ) async {
    await tester.pumpWidget(SquidAlbumApp(backend: FakeBackend()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入与同步').last);
    await tester.pumpAndSettle();
    final entry = find.byKey(const Key('device-sync-entry'));
    expect(entry, findsOneWidget);
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(DeviceSyncPage), findsOneWidget);
    expect(find.byType(DesktopWindowDragArea), findsWidgets);
    expect(find.textContaining('完成数据恢复检查'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceSyncPage), findsNothing);
  });

  testWidgets(
    'route rebuild retains one access listener and exit releases it',
    (tester) async {
      final backend = _EntryBackend();
      await tester.pumpWidget(
        pageApp(
          builder: (_) => Scaffold(
            body: DeviceSyncEntry(
              backend: backend,
              mobile: false,
              onLibraryChanged: () async {},
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-page')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('device-sync-entry')));
      await tester.pumpAndSettle();
      expect(backend.startup.listeners.length, 1);
      final route = ModalRoute.of(tester.element(find.byType(DeviceSyncPage)))!;
      route.changedExternalState();
      await tester.pumpAndSettle();
      expect(
        backend.startup.listeners.length,
        1,
        reason:
            'The same pushed page must not allocate another service access.',
      );
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(backend.startup.listeners, isEmpty);
    },
  );
}

class _EntryBackend extends FakeBackend implements DeviceSyncStartupBackend {
  final startup = _EntryStartup();
  @override
  DeviceSyncStartupLifecycle get deviceSyncStartup => startup;
  @override
  Future<void> close() => startup.close();
}

class _EntryStartup extends DeviceSyncStartupLifecycle {
  _EntryStartup()
    : super(
        gate: AccountWorkGate(),
        openLibrary: () =>
            throw StateError('No native open in entry widget fixture'),
        coordinator: (_) =>
            throw StateError('No coordinator in entry widget fixture'),
        initialize: () async {},
        isolated: false,
      );
  final listeners = <VoidCallback>{};
  @override
  void addListener(VoidCallback listener) {
    listeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners.remove(listener);
    super.removeListener(listener);
  }
}
