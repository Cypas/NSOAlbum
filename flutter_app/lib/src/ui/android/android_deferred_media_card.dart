import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../rust/models.dart';
import '../../rust/settings.dart';
import '../gallery_deferred_card.dart';
import 'android_tag.dart';

/// Same measured content geometry without mounting tags, gestures or tooltips.
class AndroidDeferredMediaCard extends StatelessWidget {
  const AndroidDeferredMediaCard({
    super.key,
    required this.asset,
    required this.settings,
    required this.builder,
    this.enabled = true,
  });
  final MediaAsset asset;
  final AppSettings settings;
  final WidgetBuilder builder;
  final bool enabled;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => GalleryDeferredCard(
      enabled: enabled,
      builder: builder,
      placeholderBuilder: (context) => SizedBox(
        key: ValueKey(('android-media-placeholder', asset.id)),
        height: _height(context, constraints.maxWidth),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
          ),
        ),
      ),
    ),
  );

  double _height(BuildContext context, double width) {
    final contentWidth = math.max(0.0, width - 16);
    final theme = Theme.of(context);
    // Card's Material installs bodyMedium as the default; Text then merges
    // bodySmall and applies platform accessibility overrides before layout.
    final style = theme.textTheme.bodyMedium!
        .merge(theme.textTheme.bodySmall?.copyWith(fontSize: 11))
        .merge(
          TextStyle(
            fontWeight: MediaQuery.boldTextOf(context) ? FontWeight.bold : null,
            height: MediaQuery.maybeLineHeightScaleFactorOverrideOf(context),
            letterSpacing: MediaQuery.maybeLetterSpacingOverrideOf(context),
            wordSpacing: MediaQuery.maybeWordSpacingOverrideOf(context),
          ),
        );
    final labels = [
      if (settings.showGameTag && asset.gameName.isNotEmpty) asset.gameName,
      ...asset.tags,
    ];
    var lineWidth = 0.0;
    var lineHeight = 0.0;
    var totalHeight = 0.0;
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(text: androidTagLabel(label), style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
        textHeightBehavior: DefaultTextHeightBehavior.maybeOf(context),
      )..layout(maxWidth: math.max(0.0, contentWidth - 12));
      // AndroidTag: 5/2 padding plus 1px border on each side.
      final tagWidth = painter.width + 12;
      final tagHeight = painter.height + 6;
      painter.dispose();
      if (lineWidth > 0 && lineWidth + 4 + tagWidth > contentWidth) {
        totalHeight += lineHeight + 3;
        lineWidth = 0;
        lineHeight = 0;
      }
      lineWidth += (lineWidth == 0 ? 0 : 4) + tagWidth;
      lineHeight = math.max(lineHeight, tagHeight);
    }
    return width * 9 / 16 + 13 + totalHeight + lineHeight;
  }
}
