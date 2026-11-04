import 'package:flutter/material.dart';

/// Observes one-finger swipes without competing with pinch-to-zoom. Playback
/// sliders live outside this region; no pointer or gesture is stolen from them.
class AndroidMediaSwipeRegion extends StatefulWidget {
  const AndroidMediaSwipeRegion({
    super.key,
    required this.child,
    required this.onSwipe,
    this.onVerticalSwipe,
    this.onHorizontalProgress,
    this.enabled = true,
  });
  final Widget child;
  final ValueChanged<int> onSwipe;
  final ValueChanged<int>? onVerticalSwipe;
  final ValueChanged<double>? onHorizontalProgress;
  final bool enabled;

  @override
  State<AndroidMediaSwipeRegion> createState() =>
      _AndroidMediaSwipeRegionState();
}

class _AndroidMediaSwipeRegionState extends State<AndroidMediaSwipeRegion> {
  final pointers = <int>{};
  Offset? start;
  bool multiTouch = false;
  bool horizontalGesture = false;
  double width = 1;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      width = constraints.maxWidth.isFinite && constraints.maxWidth > 0
          ? constraints.maxWidth
          : 1;
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          if (pointers.isEmpty) {
            start = event.position;
            multiTouch = false;
            horizontalGesture = false;
          } else {
            multiTouch = true;
            if (horizontalGesture) widget.onHorizontalProgress?.call(0);
          }
          pointers.add(event.pointer);
        },
        onPointerMove: (event) {
          final origin = start;
          if (!widget.enabled ||
              multiTouch ||
              pointers.length != 1 ||
              origin == null) {
            return;
          }
          final delta = event.position - origin;
          if (delta.dx.abs() > 6 && delta.dx.abs() > delta.dy.abs() * 1.2) {
            horizontalGesture = true;
            widget.onHorizontalProgress?.call(
              (delta.dx / width).clamp(-1.0, 1.0),
            );
          } else if (delta.dy.abs() > 6 && delta.dy.abs() > delta.dx.abs()) {
            if (horizontalGesture) widget.onHorizontalProgress?.call(0);
            horizontalGesture = false;
          }
        },
        onPointerCancel: (event) {
          pointers.remove(event.pointer);
          if (horizontalGesture) widget.onHorizontalProgress?.call(0);
          start = null;
          horizontalGesture = false;
        },
        onPointerUp: (event) {
          pointers.remove(event.pointer);
          final origin = start;
          if (pointers.isEmpty &&
              origin != null &&
              !multiTouch &&
              widget.enabled) {
            final delta = event.position - origin;
            if (horizontalGesture) widget.onHorizontalProgress?.call(0);
            if (delta.dx.abs() > 60 && delta.dx.abs() > delta.dy.abs() * 1.5) {
              widget.onSwipe(delta.dx < 0 ? 1 : -1);
            } else if (widget.onVerticalSwipe != null &&
                delta.dy.abs() > 42 &&
                delta.dy.abs() > delta.dx.abs() * 1.2) {
              widget.onVerticalSwipe!(delta.dy < 0 ? 1 : -1);
            }
            start = null;
            horizontalGesture = false;
          }
        },
        child: widget.child,
      );
    },
  );
}
