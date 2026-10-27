import 'package:flutter/material.dart';

/// Applies a short, platform-independent fade to Material routes.
///
/// Keeping this in the shared theme makes secondary pages opened through
/// MaterialPageRoute behave consistently on desktop and Android. The route's
/// own duration remains authoritative, while the interval keeps the visible
/// fade short and avoids a long blank transition.
class AppFadePageTransitionsBuilder extends PageTransitionsBuilder {
  const AppFadePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final opacity = CurvedAnimation(
      parent: animation,
      curve: const Interval(0, .78, curve: Curves.easeOutCubic),
      reverseCurve: const Interval(0, .78, curve: Curves.easeInCubic),
    );
    return FadeTransition(opacity: opacity, child: child);
  }
}

final appFadePageTransitionsTheme = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: const AppFadePageTransitionsBuilder(),
    TargetPlatform.iOS: const AppFadePageTransitionsBuilder(),
    TargetPlatform.linux: const AppFadePageTransitionsBuilder(),
    TargetPlatform.macOS: const AppFadePageTransitionsBuilder(),
    TargetPlatform.windows: const AppFadePageTransitionsBuilder(),
    TargetPlatform.fuchsia: const AppFadePageTransitionsBuilder(),
  },
);
