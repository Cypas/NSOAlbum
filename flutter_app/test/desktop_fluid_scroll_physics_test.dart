import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/ui/desktop_fluid_scroll_physics.dart';

void main() {
  const physics = DesktopFluidScrollPhysics();

  test('low-speed releases add no carried momentum', () {
    expect(physics.carriedMomentum(120), 0);
    expect(physics.carriedMomentum(-179.9), 0);
  });

  test('fast releases carry bounded momentum in the same direction', () {
    final positive = physics.carriedMomentum(1200);
    final negative = physics.carriedMomentum(-1200);
    expect(positive, greaterThan(0));
    expect(negative, lessThan(0));
    expect(positive, closeTo(-negative, 0.0001));
    expect(physics.carriedMomentum(5000).abs(), lessThanOrEqualTo(2400));
  });

  test('desktop edges use clamping ballistic behavior', () {
    final position = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 1000,
      pixels: 0,
      viewportDimension: 400,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1,
    );
    expect(physics.createBallisticSimulation(position, -1000), isNull);
  });
}
