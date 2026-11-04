@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/main.dart';
import 'package:squid_album/src/ui/platform_ui.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  testWidgets('device sync is a separate secondary transfer destination', (
    tester,
  ) async {
    await tester.pumpWidget(
      SquidAlbumApp(backend: FakeBackend(), uiPlatform: AppUiPlatform.android),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).at(2));
    await tester.pumpAndSettle();
    final entry = find.byKey(const Key('device-sync-entry'));
    expect(entry, findsOneWidget);
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(const Key('android-page-back')), findsOneWidget);
    expect(find.byTooltip('关闭'), findsNothing);
    await tester.tap(find.byKey(const Key('android-page-back')));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
