import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Adds a restrained continuation to fast Android scroll releases.
///
/// Slow drags stop promptly, while a fast fling carries a little farther
/// without changing the normal bouncing edge behavior.
class AndroidFluidScrollPhysics extends BouncingScrollPhysics {
  const AndroidFluidScrollPhysics({super.parent});

  static const _minimumFlingVelocity = 180.0;
  static const _maximumCarriedMomentum = 4000.0;

  @override
  AndroidFluidScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      AndroidFluidScrollPhysics(parent: buildParent(ancestor));

  @override
  double carriedMomentum(double existingVelocity) {
    if (existingVelocity.abs() < _minimumFlingVelocity) return 0;
    final carried = super.carriedMomentum(existingVelocity);
    return existingVelocity.sign *
        math.min(carried.abs(), _maximumCarriedMomentum);
  }
}
