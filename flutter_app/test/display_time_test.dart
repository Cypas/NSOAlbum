import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/models.dart';
import 'package:squid_album/src/ui/display_time.dart';
import 'package:squid_album/src/ui/media_metadata_editor.dart';

import 'home_shell_test.dart' show FakeBackend;

void main() {
  test('user date time is zero-padded and truncates subsecond precision', () {
    final value = DateTime(2026, 1, 2, 3, 4, 5, 987, 654);

    expect(formatUserDateTime(value), '2026-01-02 03:04:05');
  });

  test('NSO account attempt time omits the year and keeps seconds', () {
    final value = DateTime(2026, 1, 2, 3, 4, 5, 987, 654);

    expect(formatNsoAttemptTime(value), '01-02 03:04:05');
  });

  test('subsecond precision never rounds into the next day or year', () {
    final value = DateTime(2026, 12, 31, 23, 59, 59, 999, 999);

    expect(formatUserDateTime(value), '2026-12-31 23:59:59');
    expect(formatNsoAttemptTime(value), '12-31 23:59:59');
    expect(
      formatUserDateTime(value.add(const Duration(microseconds: 1))),
      '2027-01-01 00:00:00',
    );
    expect(
      formatNsoAttemptTime(value.add(const Duration(microseconds: 1))),
      '01-01 00:00:00',
    );
  });

  test('user date time converts UTC input to the system local timezone', () {
    final value = DateTime.utc(2026, 12, 31, 23, 59, 58, 999, 999);
    final local = value.toLocal();
    final expected =
        '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}';

    expect(formatUserDateTime(value), expected);
  });

  for (final locale in ['zh', 'en']) {
    testWidgets('desktop metadata uses seconds and unknown time in $locale', (
      tester,
    ) async {
      Future<void> show(DateTime? capturedAt) async {
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: MediaMetadataEditor(
                key: ValueKey(capturedAt),
                backend: FakeBackend(),
                asset: MediaAsset(
                  id: 1,
                  sha256: 'synthetic',
                  originalName: 'test.png',
                  storagePath: 'missing.png',
                  kind: MediaKind.image,
                  capturedAt: capturedAt,
                  importedAt: DateTime(2026, 10, 15),
                  gameName: 'Game',
                  favorite: false,
                  tags: const [],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show(DateTime(2026, 10, 15, 9, 8, 7, 654, 321));
      final text = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(text.data, contains('2026-10-15 09:08:07\n'));
      expect(text.data, isNot(contains('.654321')));

      await show(null);
      final unknown = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(
        unknown.data,
        contains(locale == 'zh' ? '创建时间：未知' : 'Created at: Unknown'),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
