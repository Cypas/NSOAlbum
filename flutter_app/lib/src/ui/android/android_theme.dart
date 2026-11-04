import 'package:flutter/material.dart';

import '../fade_page_transitions.dart';

ThemeData androidTheme(String name) {
  final seed = switch (name) {
    'teal' => const Color(0xff159b88),
    'orange' => const Color(0xffdf754d),
    'purple' => const Color(0xff8562ca),
    'rose' => const Color(0xffcf5d82),
    _ => const Color(0xff5577e8),
  };
  final base = ThemeData(
    useMaterial3: true,
    platform: TargetPlatform.android,
    colorScheme: ColorScheme.fromSeed(seedColor: seed),
  );
  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      headlineMedium: base.textTheme.headlineMedium?.copyWith(fontSize: 24),
      titleLarge: base.textTheme.titleLarge?.copyWith(fontSize: 24),
      titleMedium: base.textTheme.titleMedium?.copyWith(fontSize: 20),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 16),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 14),
      bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 12),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
    ),
    pageTransitionsTheme: appFadePageTransitionsTheme,
  );
}
