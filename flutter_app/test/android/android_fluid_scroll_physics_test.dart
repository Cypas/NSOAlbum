@Tags(['platform-android'])
library;

import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/ui/android/android_albums_page.dart';
import 'package:squid_album/src/ui/android/android_fluid_scroll_physics.dart';

import '../home_shell_test.dart' show FakeBackend;

void main() {
  const physics = AndroidFluidScrollPhysics();

  test('low-speed releases add no carried momentum', () {
    expect(physics.carriedMomentum(120), 0);
    expect(physics.carriedMomentum(-120), 0);
    expect(physics.carriedMomentum(179.9), 0);
  });

  test('high-speed releases preserve direction and bounded momentum', () {
    final positive = physics.carriedMomentum(1200);
    final negative = physics.carriedMomentum(-1200);
    expect(positive, greaterThan(0));
    expect(negative, lessThan(0));
    expect(positive, closeTo(-negative, 0.0001));
    expect(physics.carriedMomentum(2400).abs(), lessThanOrEqualTo(4000));
    expect(physics.carriedMomentum(2400).abs(),
        greaterThanOrEqualTo(physics.carriedMomentum(1200).abs()));
  });

  test('applies a normal ballistic simulation at the scroll boundary', () {
    final position = FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 1000,
      pixels: 0,
      viewportDimension: 400,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1,
    );
    final simulation = physics.createBallisticSimulation(position, -1000);
    expect(simulation, isA<Simulation>());
  });

  testWidgets('albums grid uses the shared fluid physics', (tester) async {
    final backend = FakeBackend();
    final settings = SettingsController(backend);
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [AppLocalizations.delegate],
        supportedLocales: AppLocalizations.supportedLocales,
        home: AndroidAlbumsPage(backend: backend, settings: settings),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<GridView>(find.byType(GridView)).physics,
      isA<AndroidFluidScrollPhysics>(),
    );
  });
}
