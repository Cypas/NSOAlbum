import 'package:pinyin/pinyin.dart';

/// Normalizes user-facing search text without changing the stored spelling.
///
/// Traditional Chinese is converted to Simplified Chinese and Unicode-aware
/// lowercase matching is applied to the rest of the text.
String normalizeSearchText(String value) =>
    ChineseHelper.convertToSimplifiedChinese(value).toLowerCase();

bool normalizedTextContains(String text, String query) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return true;
  final includePhonetic = trimmed.runes.any(
    (rune) => ChineseHelper.isChinese(String.fromCharCode(rune)),
  );
  final textAliases = _searchAliases(text, includePhonetic: includePhonetic);
  final queryAliases = _searchAliases(
    trimmed,
    includePhonetic: includePhonetic,
  );
  return queryAliases.any(
    (candidate) =>
        candidate.isNotEmpty &&
        textAliases.any((source) => source.contains(candidate)),
  );
}

Set<String> _searchAliases(String value, {required bool includePhonetic}) {
  final original = value.toLowerCase();
  final simplified = ChineseHelper.convertToSimplifiedChinese(original)
      .toLowerCase();
  final traditional = ChineseHelper.convertToTraditionalChinese(original)
      .toLowerCase();
  return {
    original,
    simplified,
    traditional,
    if (includePhonetic) _phoneticFold(original),
    if (includePhonetic) _phoneticFold(simplified),
    if (includePhonetic) _phoneticFold(traditional),
  };
}

String _phoneticFold(String value) {
  final result = StringBuffer();
  for (final rune in value.runes) {
    final character = String.fromCharCode(rune);
    if (!ChineseHelper.isChinese(character)) {
      result.write(character.toLowerCase());
      continue;
    }
    try {
      result.write(PinyinHelper.getPinyin(character, separator: ''));
    } catch (_) {
      result.write(character);
    }
  }
  return result.toString();
}
