import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/fonts/custom_font_store.dart';
import 'package:squid_album/src/rust/settings.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/ui/font_families.dart';

import 'home_shell_test.dart' show FakeBackend;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final commonPath = File(
    'assets/fonts/splatoon_web/Splatoon2-common-2LVXcHij.ttf',
  ).absolute.path;
  final chinesePath = File(
    'assets/fonts/splatoon_web/Splatoon2CHzh-level1-CUZXdiKS.ttf',
  ).absolute.path;

  setUp(() async {
    await loadCustomFontFamilies(const []);
  });

  test('built-in web font shards are real OpenType/TrueType files', () async {
    final paths = [
      commonPath,
      chinesePath,
      ...[
        'Splatoon2-symbol-common-aF2KKpUQ.ttf',
        'Splatoon2-cjk-common-BEzXpdSx.ttf',
        'Splatoon2CHzh-level2-DDnDbTcP.ttf',
        'Splatoon2JP-level1-rL37kLr1.ttf',
        'Splatoon2JP-level2-DR2Y1cVj.ttf',
        'Splatoon2JP-hiragana-katakana-D98dgzMx.ttf',
      ].map((name) => 'assets/fonts/splatoon_web/$name'),
    ];
    await CustomFontStore.validateFiles(paths);
    final report = await prepareCustomFontFamilies(paths);
    expect(report.loadedFamilies, hasLength(paths.length));
    expect(report.failedPaths, isEmpty);
    // Preparing resources must not replace the live built-in font chain.
    expect(appFontFamily, 'Splatoon2');
  });

  test('renamed WOFF2 cannot be accepted as a custom TTF font', () async {
    final directory = await Directory.systemTemp.createTemp('font-format-');
    addTearDown(() => directory.delete(recursive: true));
    final renamed = await File(
      'assets/fonts/splatoon_web/Splatoon2-common-2LVXcHij.woff2',
    ).copy('${directory.path}${Platform.pathSeparator}renamed.ttf');

    await expectLater(
      prepareCustomFontFamilies([renamed.path]),
      throwsA(isA<FormatException>()),
    );
    expect(appFontFamily, 'Splatoon2');
  });

  test('uses the web font shard chain for simplified Chinese', () {
    expect(builtInFontFallbackForLanguage('zh'), const [
      'Splatoon2Symbol',
      'Splatoon2Cjk',
      'Splatoon2ChzhLevel1',
      'Splatoon2ChzhLevel2',
    ]);
  });

  test('uses the web font shard chain for English', () {
    expect(builtInFontFallbackForLanguage('en'), const [
      'Splatoon2Symbol',
      'Splatoon2Cjk',
      'Splatoon2JpLevel1',
      'Splatoon2JpLevel2',
      'Splatoon2JpKana',
    ]);
  });

  test('empty custom font configuration restores the built-in chain', () async {
    final report = await loadCustomFontFamilies(const [], language: 'zh');

    expect(report.loadedFamilies, isEmpty);
    expect(appFontFamily, 'Splatoon2');
    expect(appFontFallback, builtInFontFallbackForLanguage('zh'));
  });

  test('switching language changes only the built-in fallback shards', () {
    selectAppFontLanguage('en');
    expect(appFontFamily, 'Splatoon2');
    expect(appFontFallback, contains('Splatoon2JpLevel1'));
    expect(appFontFallback, isNot(contains('Splatoon2ChzhLevel1')));
    selectAppFontLanguage('zh');
    expect(appFontFallback, contains('Splatoon2ChzhLevel1'));
    expect(appFontFallback, isNot(contains('Splatoon2JpLevel1')));
  });

  test(
    'custom fonts keep their order and exclude all built-in shards',
    () async {
      final report = await loadCustomFontFamilies([commonPath, chinesePath]);

      expect(appFontFamily, report.loadedFamilies.first);
      expect(appFontFallback, [report.loadedFamilies.last]);
      expect(appFontFallback, isNot(contains('Splatoon2Cjk')));
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
      expect(appFontFamily, 'Splatoon2');
      expect(appFontFallback, contains('Splatoon2JpLevel1'));
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
      expect(appFontFamily, 'Splatoon2');
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
    expect(appFontFamily, 'Splatoon2');
  });
}

// A test-only fixture keeps the DTO copy separate from production typography.
AppSettings _withFonts(FakeBackend backend, List<String> paths) {
  final value = backend.settings;
  return AppSettings(
    proxyUrl: value.proxyUrl,
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
