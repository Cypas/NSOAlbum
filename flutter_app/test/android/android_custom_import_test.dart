import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:squid_album/src/backend/app_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/state/sync_controller.dart';
import 'package:squid_album/src/state/transfer_controller.dart';
import 'package:squid_album/src/ui/android/android_custom_import_page.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  testWidgets('selected media shows basename previews without full paths', (
    tester,
  ) async {
    final backend = FakeBackend(mediaItems: []);
    final settings = SettingsController(backend);
    final sync = SyncController(backend);
    final transfer = TransferController(backend, settings, sync)
      ..addPaths(['C:/private/DCIM/photo.png', 'C:/private/DCIM/clip.mp4']);

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
        home: AndroidCustomImportPage(controller: transfer),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('photo.png'), findsOneWidget);
    expect(find.text('clip.mp4'), findsOneWidget);
    expect(find.textContaining('C:/private'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.movie_outlined), findsOneWidget);

    transfer.importProgress = const OperationProgressValue(
      operationId: 'import-1',
      kind: 'custom_import',
      phase: 'discovering',
    );
    transfer.publish();
    await tester.pump();
    expect(find.text('正在扫描可导入媒体…'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      isNull,
    );

    transfer.importProgress = const OperationProgressValue(
      operationId: 'import-1',
      kind: 'custom_import',
      phase: 'importing',
      processed: 2,
      total: 4,
    );
    transfer.publish();
    await tester.pump();
    expect(find.text('正在导入 2 / 4'), findsOneWidget);

    await tester.tap(find.byTooltip('移除').first);
    await tester.pump();
    expect(find.text('photo.png'), findsNothing);

    transfer.dispose();
    sync.dispose();
    settings.dispose();
  }, variant: TargetPlatformVariant({TargetPlatform.android}));
}
