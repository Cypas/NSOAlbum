import 'dart:math' as math;

import 'package:flutter/material.dart';

double androidPagePadding(double width) =>
    width < 600 ? 12 : (width < 840 ? 16 : 24);

double androidCardSpacing(double width) =>
    width < 600 ? 8 : (width < 840 ? 12 : 16);

int androidGalleryColumns({
  required double width,
  required int preferredColumns,
  required TextScaler textScaler,
  required double spacing,
}) {
  final minimum = 144 * math.max(1, textScaler.scale(14) / 14);
  final maximum = ((width + spacing) / (minimum + spacing)).floor();
  return math.min(preferredColumns.clamp(1, 7), math.max(1, maximum));
}
