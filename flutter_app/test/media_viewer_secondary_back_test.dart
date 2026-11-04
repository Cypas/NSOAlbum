import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/media_viewer.dart';

import 'home_shell_test.dart' show FakeBackend;

void main() {
  final items = [
    MediaAsset(
      id: 1,
      sha256: 'secondary-back-image',
      originalName: 'preview.png',
      storagePath: 'missing-preview.png',
      kind: MediaKind.image,
      gameName: 'Game',
      favorite: false,
      tags: const [],
    ),
  ];

  Future<void> openViewer(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                key: const Key('open-media-viewer'),
                onPressed: () => MediaViewer.open(
                  context,
                  backend: FakeBackend(mediaItems: items),
                  items: items,
                  initialIndex: 0,
                  autoPlayVideo: false,
                  compactTagDisplay: false,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-media-viewer')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('media-viewer-dialog')), findsOneWidget);
  }

  testWidgets('secondary click closes the desktop viewer, primary does not', (
    tester,
  ) async {
    await openViewer(tester);

    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('media-viewer-dialog')),
      findsOneWidget,
      reason: 'A primary click must keep the viewer open.',
    );

    await tester.tapAt(const Offset(400, 300), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('media-viewer-dialog')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('secondary click over the bottom toolbar also leaves', (
    tester,
  ) async {
    await openViewer(tester);

    await tester.tapAt(const Offset(400, 560), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('media-viewer-dialog')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
