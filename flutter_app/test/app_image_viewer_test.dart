import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/app_image_viewer.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';

void main() {
  testWidgets('image viewer opens and switches between guide images', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAppImageViewer(
              context,
              items: const [
                AppImageViewerItem(
                  image: AssetImage('assets/images/import/import_step1.jpg'),
                  label: 'Step 1',
                ),
                AppImageViewerItem(
                  image: AssetImage('assets/images/import/import_step2.jpg'),
                  label: 'Step 2',
                ),
              ],
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-image-viewer-pages')), findsOneWidget);
    expect(find.text('Step 1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('app-image-viewer-next')));
    await tester.pumpAndSettle();
    expect(find.text('Step 2'), findsOneWidget);
  });

  testWidgets('image viewer save action follows the interface language', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [AppLocalizations.delegate],
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAppImageViewer(
              context,
              items: const [
                AppImageViewerItem(
                  image: AssetImage('assets/images/import/import_step1.jpg'),
                  label: 'Step 1',
                ),
              ],
              onSave: (_) async {},
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Save as'), findsOneWidget);
    expect(find.text('另存为 / Save as'), findsNothing);
  });
}
