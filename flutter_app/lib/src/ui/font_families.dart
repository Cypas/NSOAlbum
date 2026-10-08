import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../fonts/custom_font_store.dart';

String _language = 'zh';
List<String> _customFamilies = const [];
final appFontRevision = ValueNotifier<int>(0);
final _loadedFamilies = <String, Future<void>>{};

String get appFontFamily =>
    _customFamilies.isEmpty ? 'Splatoon2' : _customFamilies.first;
List<String> get appFontFallback => _customFamilies.isEmpty
    ? builtInFontFallbackForLanguage(_language)
    : List<String>.unmodifiable(_customFamilies.skip(1));

List<String> builtInFontFallbackForLanguage(String language) => [
  'Splatoon2Symbol',
  'Splatoon2Cjk',
  if (language == 'zh') ...[
    'Splatoon2ChzhLevel1',
    'Splatoon2ChzhLevel2',
  ] else ...[
    'Splatoon2JpLevel1',
    'Splatoon2JpLevel2',
    'Splatoon2JpKana',
  ],
];

void selectAppFontLanguage(String language) {
  if (_language == language) return;
  _language = language;
  if (_customFamilies.isEmpty) appFontRevision.value++;
}

void applyCustomFontReport(FontLoadReport report, {required String language}) {
  _customFamilies = List<String>.unmodifiable(report.loadedFamilies);
  _language = language;
  appFontRevision.value++;
}

class FontLoadReport {
  const FontLoadReport({
    required this.loadedFamilies,
    required this.failedPaths,
  });

  final List<String> loadedFamilies;
  final List<String> failedPaths;
}

Future<void> validateCustomFontFiles(List<String> paths) async {
  await prepareCustomFontFamilies(paths);
}

/// Registers fonts without changing the visible chain. Used before persistence
/// so failed loads or settings writes cannot replace the current typography.
Future<FontLoadReport> prepareCustomFontFamilies(List<String> paths) async {
  final loaded = <String>[];
  for (final path in paths) {
    loaded.add(await _loadFont(path));
  }
  return FontLoadReport(loadedFamilies: loaded, failedPaths: const []);
}

Future<FontLoadReport> loadCustomFontFamilies(
  List<String> paths, {
  String language = 'zh',
}) async {
  final loaded = <String>[];
  final failed = <String>[];
  for (final path in paths) {
    try {
      loaded.add(await _loadFont(path));
    } catch (_) {
      failed.add(path);
    }
  }
  final report = FontLoadReport(
    loadedFamilies: List.unmodifiable(loaded),
    failedPaths: List.unmodifiable(failed),
  );
  applyCustomFontReport(report, language: language);
  return report;
}

Future<String> _loadFont(String path) async {
  await CustomFontStore.validateFiles([path]);
  final file = File(path);
  final bytes = await file.readAsBytes();
  // Only the runtime family uses a content ID. Stored files keep original names.
  final family = 'NSOAlbumCustomFont_${sha256.convert(bytes)}';
  final registration = _loadedFamilies.putIfAbsent(family, () {
    final loader = FontLoader(family);
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
    return loader.load();
  });
  try {
    await registration;
  } catch (_) {
    _loadedFamilies.remove(family);
    rethrow;
  }
  return family;
}
