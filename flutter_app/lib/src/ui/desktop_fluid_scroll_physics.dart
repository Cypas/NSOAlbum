import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Keeps desktop drag releases bounded while preserving clamping edges.
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

/// Marks wheel input without stealing nested scrollables' signal resolution.
class DesktopWheelScrollNotification extends Notification {
  const DesktopWheelScrollNotification({
    required this.position,
    required this.wheel,
    this.detached = false,
  });
  final ScrollPosition position;
  final bool wheel;
  final bool detached;
}

class DesktopSmoothScroll extends StatelessWidget {
  const DesktopSmoothScroll({
    super.key,
    required this.controller,
    required this.child,
  });
  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
    // The resolver calls pointerScroll after the whole hit-test path is visited.
    onPointerSignal: (event) {
      final target = controller;
      if (target is DesktopGalleryScrollController) {
        target.wheelInput =
            event is PointerScrollEvent &&
            event.kind == PointerDeviceKind.mouse;
        target.smoothWheel =
            target.wheelInput && !MediaQuery.disableAnimationsOf(context);
      }
    },
    child: child,
  );
}

class DesktopGalleryScrollController extends ScrollController {
  bool smoothWheel = false;
  bool wheelInput = false;

  @override
  void detach(ScrollPosition position) {
    final notificationContext = position.context.notificationContext;
    if (notificationContext != null) {
      DesktopWheelScrollNotification(
        position: position,
        wheel: false,
        detached: true,
      ).dispatch(notificationContext);
    }
    super.detach(position);
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _SmoothWheelPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    smooth: () => smoothWheel,
    wheelInput: () => wheelInput,
  );
}

class _SmoothWheelPosition extends ScrollPositionWithSingleContext {
  _SmoothWheelPosition({
    required super.physics,
    required super.context,
    required super.oldPosition,
    required super.initialPixels,
    required super.keepScrollOffset,
    required this.smooth,
    required this.wheelInput,
  });
  final bool Function() smooth;
  final bool Function() wheelInput;
  double? _target;
  double _direction = 0;
  int _generation = 0;

  @override
  void pointerScroll(double delta) {
    final smoothInput = smooth();
    final base = smoothInput && _target != null && delta.sign == _direction
        ? _target!
        : pixels;
    final target = (base + delta).clamp(minScrollExtent, maxScrollExtent);
    final wheel = wheelInput() && delta != 0;
    // Only the ScrollPosition chosen by Flutter's signal resolver emits this.
    // Raw hit testing would also pause galleries behind nested scrollables.
    if (!wheel || target != pixels) {
      final notificationContext = context.notificationContext;
      if (notificationContext != null) {
        DesktopWheelScrollNotification(
          position: this,
          wheel: wheel,
        ).dispatch(notificationContext);
      }
    }
    if (!smoothInput || delta == 0) {
      _target = null;
      _generation++;
      super.pointerScroll(delta);
      return;
    }
    _direction = delta.sign;
    _target = target;
    final generation = ++_generation;
    unawaited(
      animateTo(
        target,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOutCubic,
      ).whenComplete(() {
        if (generation == _generation) _target = null;
      }),
    );
  }
}
