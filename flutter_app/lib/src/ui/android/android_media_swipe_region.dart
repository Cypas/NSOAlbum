import 'package:flutter/material.dart';

/// Observes one-finger swipes without competing with pinch-to-zoom. Playback
/// sliders live outside this region; no pointer or gesture is stolen from them.
class AndroidMediaSwipeRegion extends StatefulWidget {
  const AndroidMediaSwipeRegion({
    super.key,
    required this.child,
    required this.onSwipe,
    this.onVerticalSwipe,
    this.enabled = true,
  });
  final Widget child;
  final ValueChanged<int> onSwipe;
  final ValueChanged<int>? onVerticalSwipe;
  final bool enabled;

  @override
  State<AndroidMediaSwipeRegion> createState() =>
      _AndroidMediaSwipeRegionState();
}

class _AndroidMediaSwipeRegionState extends State<AndroidMediaSwipeRegion> {
  final pointers = <int>{};
  Offset? start;
  bool multiTouch = false;
  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerDown: (event) {
      if (pointers.isEmpty) {
        start = event.position;
        multiTouch = false;
      } else {
        multiTouch = true;
      }
      pointers.add(event.pointer);
    },
    onPointerCancel: (event) {
      pointers.remove(event.pointer);
      start = null;
    },
    onPointerUp: (event) {
      pointers.remove(event.pointer);
      final origin = start;
      if (pointers.isEmpty && origin != null && !multiTouch && widget.enabled) {
        final delta = event.position - origin;
        if (delta.dx.abs() > 60 && delta.dx.abs() > delta.dy.abs() * 1.5) {
          widget.onSwipe(delta.dx < 0 ? 1 : -1);
        } else if (widget.onVerticalSwipe != null &&
            delta.dy.abs() > 42 &&
            delta.dy.abs() > delta.dx.abs() * 1.2) {
          widget.onVerticalSwipe!(delta.dy < 0 ? 1 : -1);
        }
        start = null;
      }
    },
    child: widget.child,
  );
}
