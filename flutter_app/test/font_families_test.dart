import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/fonts/custom_font_store.dart';
import 'package:squid_album/src/rust/settings.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/ui/font_families.dart';

import 'home_shell_test.dart' show FakeBackend;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final commonPath = File('assets/fonts/default/BlitzMain.otf').absolute.path;
  final chinesePath = File('assets/fonts/default/DFPT_ZY9.ttf').absolute.path;

  setUp(() async {
    await loadCustomFontFamilies(const []);
  });

  test(
    'bundled default fonts are loadable OpenType/TrueType resources',
    () async {
      final paths = [
        commonPath,
        chinesePath,
        'assets/fonts/default/DFP_GBZY9.ttf',
      ];
      await CustomFontStore.validateFiles(paths);
      final report = await prepareCustomFontFamilies(paths);
      expect(report.loadedFamilies, hasLength(paths.length));
      expect(report.failedPaths, isEmpty);
      // Preparing resources must not replace the live built-in font chain.
      expect(appFontFamily, 'DFPT_ZY9');
      for (final name in ['DFPT_ZY9.ttf', 'DFP_GBZY9.ttf', 'BlitzMain.otf']) {
        final bytes = await rootBundle.load('assets/fonts/default/$name');
        expect(bytes.lengthInBytes, greaterThan(0));
      }
    },
  );

  test('renamed WOFF2 cannot be accepted as a custom TTF font', () async {
    final directory = await Directory.systemTemp.createTemp('font-format-');
    addTearDown(() => directory.delete(recursive: true));
    // Only the signature matters for rejection; no third-party webfont is
    // needed as a fixture.
    final renamed = await File(
      '${directory.path}${Platform.pathSeparator}renamed.ttf',
    ).writeAsBytes([0x77, 0x4f, 0x46, 0x32, 0, 0, 0, 0]); // wOF2

    await expectLater(
      prepareCustomFontFamilies([renamed.path]),
      throwsA(isA<FormatException>()),
    );
    expect(appFontFamily, 'DFPT_ZY9');
  });

  test(
    'TrueType collections are accepted while bitmap fonts are rejected',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'font-collection-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final collection =
          await File('${directory.path}${Platform.pathSeparator}collection.ttc')
              .writeAsBytes([
                0x74, 0x74, 0x63, 0x66, // ttcf
                0, 1, 0, 0,
              ]);
      final openTypeCollection =
          await File('${directory.path}${Platform.pathSeparator}collection.otc')
              .writeAsBytes([
                0x74, 0x74, 0x63, 0x66, // ttcf
                0, 1, 0, 0,
              ]);
      final bitmap = await File(
        '${directory.path}${Platform.pathSeparator}bitmap.fon',
      ).writeAsBytes([0x4d, 0x5a, 0, 0]);

      await expectLater(
        CustomFontStore.validateFiles([collection.path]),
        completes,
      );
      await expectLater(
        CustomFontStore.validateFiles([openTypeCollection.path]),
        completes,
      );
      await expectLater(
        CustomFontStore.validateFiles([bitmap.path]),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'an installed Windows TrueType collection can be loaded by the runtime',
    () async {
      if (!Platform.isWindows) return;
      final directory = Directory(r'C:\Windows\Fonts');
      if (!await directory.exists()) return;
      final installedCollection = directory
          .listSync()
          .whereType<File>()
          .where(
            (file) =>
                file.path.toLowerCase().endsWith('.ttc') ||
                file.path.toLowerCase().endsWith('.otc'),
          )
          .firstOrNull;
      if (installedCollection == null) return;

      final report = await loadCustomFontFamilies([installedCollection.path]);

      expect(report.loadedFamilies, hasLength(1));
      expect(report.failedPaths, isEmpty);
    },
  );

  test('uses the configured default priority for simplified Chinese', () {
    selectAppFontLanguage('zh');
    expect(appFontFamily, 'DFPT_ZY9');
    expect(builtInFontFallbackForLanguage('zh'), const [
      'DFP_GBZY9',
      'BlitzMain',
    ]);
  });

  test('uses the configured default priority for English', () {
    selectAppFontLanguage('en');
    expect(appFontFamily, 'BlitzMain');
    expect(builtInFontFallbackForLanguage('en'), const [
      'DFPT_ZY9',
      'DFP_GBZY9',
    ]);
  });

  test('empty custom font configuration restores the built-in chain', () async {
    final report = await loadCustomFontFamilies(const [], language: 'zh');

    expect(report.loadedFamilies, isEmpty);
    expect(appFontFamily, 'DFPT_ZY9');
    expect(appFontFallback, ['DFP_GBZY9', 'BlitzMain']);
  });

  test(
    'switching language updates the default main font and fallback order',
    () {
      final revision = appFontRevision.value;
      selectAppFontLanguage('en');
      expect(appFontFamily, 'BlitzMain');
      expect(appFontFallback, ['DFPT_ZY9', 'DFP_GBZY9']);
      expect(appFontRevision.value, revision + 1);
      selectAppFontLanguage('zh');
      expect(appFontFamily, 'DFPT_ZY9');
      expect(appFontFallback, ['DFP_GBZY9', 'BlitzMain']);
      expect(appFontRevision.value, revision + 2);
    },
  );

  test(
    'custom fonts keep their order and fully replace the default chain',
    () async {
      final report = await loadCustomFontFamilies([commonPath, chinesePath]);

      expect(appFontFamily, report.loadedFamilies.first);
      expect(appFontFallback, [report.loadedFamilies.last]);
      expect(appFontFallback, isNot(contains('DFP_GBZY9')));
      selectAppFontLanguage('en');
      expect(appFontFamily, report.loadedFamilies.first);
      expect(appFontFallback, [report.loadedFamilies.last]);
    },
  );

  test(
    'applying reordered fonts changes priority with stable family identities',
    () async {
      final first = await loadCustomFontFamilies([commonPath, chinesePath]);

      final next = await loadCustomFontFamilies([chinesePath, commonPath]);

      expect(appFontFamily, first.loadedFamilies.last);
      expect(appFontFallback, [first.loadedFamilies.first]);
      expect(next.loadedFamilies, first.loadedFamilies.reversed);
    },
  );

  test('different contents never reuse a positional font family', () async {
    final first = await loadCustomFontFamilies([commonPath]);
    final next = await loadCustomFontFamilies([chinesePath]);
    expect(appFontFamily, isNot(first.loadedFamilies.single));
    expect(appFontFamily, next.loadedFamilies.single);
    expect(appFontFallback, isEmpty);
  });

  test(
    'failed startup fonts fall back to the current language chain',
    () async {
      final report = await loadCustomFontFamilies([
        'missing-font.ttf',
      ], language: 'en');
      expect(report.failedPaths, ['missing-font.ttf']);
      expect(appFontFamily, 'BlitzMain');
      expect(appFontFallback, ['DFPT_ZY9', 'DFP_GBZY9']);
    },
  );

  test('validation failure does not change the active font chain', () async {
    await loadCustomFontFamilies([commonPath]);
    final previous = appFontFamily;
    await expectLater(
      prepareCustomFontFamilies([chinesePath, 'missing-font.ttf']),
      throwsA(isA<FormatException>()),
    );
    expect(appFontFamily, previous);
    expect(appFontFallback, isEmpty);
  });

  test(
    'saving font order updates the active chain and persists settings',
    () async {
      final backend = FakeBackend();
      final controller = SettingsController(backend);
      addTearDown(controller.dispose);
      final report = await prepareCustomFontFamilies([commonPath, chinesePath]);

      await controller.save(_withFonts(backend, [commonPath, chinesePath]));

      expect(backend.settings.customFontPaths, [commonPath, chinesePath]);
      expect(appFontFamily, report.loadedFamilies.first);
      expect(appFontFallback, [report.loadedFamilies.last]);
    },
  );

  test(
    'failed settings write preserves the previously active font chain',
    () async {
      final backend = _FailingSettingsBackend();
      final controller = SettingsController(backend);
      addTearDown(controller.dispose);
      final previous = List.of(appFontFallback);

      await expectLater(
        controller.save(_withFonts(backend, [chinesePath])),
        throwsA(isA<StateError>()),
      );

      expect(backend.settings.customFontPaths, isEmpty);
      expect(appFontFamily, 'DFPT_ZY9');
      expect(appFontFallback, previous);
    },
  );

  test('invalid font configuration is not saved', () async {
    final backend = FakeBackend();
    final controller = SettingsController(backend);
    addTearDown(controller.dispose);

    await expectLater(
      controller.save(_withFonts(backend, ['missing-font.ttf'])),
      throwsA(isA<FormatException>()),
    );

    expect(backend.settings.customFontPaths, isEmpty);
    expect(appFontFamily, 'DFPT_ZY9');
  });
}

// A test-only fixture keeps the DTO copy separate from production typography.
AppSettings _withFonts(FakeBackend backend, List<String> paths) {
  final value = backend.settings;
  return AppSettings(
    proxyUrl: value.proxyUrl,
    dohEnabled: value.dohEnabled,
    libraryPath: value.libraryPath,
    theme: value.theme,
    language: value.language,
    galleryColumns: value.galleryColumns,
    galleryRows: value.galleryRows,
    showNotePreview: value.showNotePreview,
    showGameTag: value.showGameTag,
    compactTagDisplay: value.compactTagDisplay,
    autoPlayVideo: value.autoPlayVideo,
    autoSyncOnLaunch: value.autoSyncOnLaunch,
    notifyOnAutoSync: value.notifyOnAutoSync,
    showSplatoonSchedule: value.showSplatoonSchedule,
    showSplatoonFriendActivity: value.showSplatoonFriendActivity,
    closeBehavior: value.closeBehavior,
    customFontPaths: paths,
    syncPolicy: value.syncPolicy,
  );
}

class _FailingSettingsBackend extends FakeBackend {
  @override
  Future<void> saveSettings(AppSettings value) async =>
      throw StateError('write failed');
}
