import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Keeps desktop drag releases bounded while preserving clamping edges.
///
/// Mouse-wheel and trackpad deltas are handled by Flutter's normal scroll
/// activity; this only adds a small, capped continuation to touch/drag
/// releases.
class DesktopFluidScrollPhysics extends ClampingScrollPhysics {
  const DesktopFluidScrollPhysics({super.parent});

  static const _minimumFlingVelocity = 180.0;
  static const _maximumCarriedMomentum = 2400.0;

  @override
  DesktopFluidScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      DesktopFluidScrollPhysics(parent: buildParent(ancestor));

  @override
  double carriedMomentum(double existingVelocity) {
    final speed = existingVelocity.abs();
    if (speed < _minimumFlingVelocity) return 0;
    final carried = (speed - _minimumFlingVelocity) * .6;
    return existingVelocity.sign * math.min(carried, _maximumCarriedMomentum);
  }
}
