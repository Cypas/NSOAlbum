import 'package:flutter/material.dart';

/// Ten narrow character cells, or five CJK/emoji graphemes.
String androidTagLabel(String label) {
  var width = 0;
  final result = StringBuffer();
  for (final character in label.characters) {
    final rune = character.runes.first;
    final cells = rune <= 0x7f ? 1 : 2;
    if (width + cells > 10) return '$result..';
    result.write(character);
    width += cells;
  }
  return label;
}

class AndroidTag extends StatelessWidget {
  const AndroidTag({
    super.key,
    required this.label,
    this.game = false,
    this.compact = false,
  });
  final String label;
  final bool game;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 5 : 6,
          vertical: compact ? 2 : 4,
        ),
        decoration: BoxDecoration(
          color: game ? colors.primaryContainer : colors.secondaryContainer,
          borderRadius: BorderRadius.circular(compact ? 6 : 8),
          border: Border.all(
            color: (game ? colors.primary : colors.secondary).withValues(
              alpha: .3,
            ),
          ),
        ),
        child: Text(
          compact ? androidTagLabel(label) : label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontSize: compact ? 11 : null,
            color: game
                ? colors.onPrimaryContainer
                : colors.onSecondaryContainer,
          ),
        ),
      ),
    );
  }
}
