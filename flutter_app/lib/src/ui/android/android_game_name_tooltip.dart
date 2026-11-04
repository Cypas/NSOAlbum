import 'dart:async';

import 'package:flutter/material.dart';

/// Unlike TooltipTriggerMode.longPress, this also prevents mouse hover from
/// revealing a name on Android devices with an attached mouse.
class AndroidGameNameTooltip extends StatefulWidget {
  const AndroidGameNameTooltip({
    super.key,
    required this.message,
    required this.child,
  });

  final String message;
  final Widget child;

  @override
  State<AndroidGameNameTooltip> createState() => _AndroidGameNameTooltipState();
}

class _AndroidGameNameTooltipState extends State<AndroidGameNameTooltip> {
  final _tooltipKey = GlobalKey<TooltipState>();
  Timer? _dismissTimer;
  bool _allowed = false;
  int _generation = 0;

  void _show() {
    _dismissTimer?.cancel();
    final generation = ++_generation;
    setState(() => _allowed = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_allowed || generation != _generation) return;
      _tooltipKey.currentState?.ensureTooltipVisible();
    });
  }

  void _release(LongPressEndDetails _) {
    if (!_allowed) return;
    _dismissTimer?.cancel();
    _dismissTimer = Timer(
      TooltipTheme.of(context).showDuration ??
          const Duration(milliseconds: 1500),
      _hide,
    );
  }

  void _hide() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _generation++;
    if (mounted && _allowed) setState(() => _allowed = false);
  }

  @override
  void didUpdateWidget(AndroidGameNameTooltip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message != widget.message) {
      _dismissTimer?.cancel();
      _dismissTimer = null;
      _generation++;
      _allowed = false;
    }
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    // Preserve the complete accessible name while visual tooltips are gated.
    tooltip: widget.message,
    child: MouseRegion(
      onExit: (_) => _hide(),
      child: Listener(
        onPointerCancel: (_) => _hide(),
        child: GestureDetector(
          onLongPress: _show,
          onLongPressEnd: _release,
          onLongPressCancel: _hide,
          child: TooltipVisibility(
            visible: _allowed && TooltipVisibility.of(context),
            child: Tooltip(
              key: _tooltipKey,
              message: widget.message,
              excludeFromSemantics: true,
              triggerMode: TooltipTriggerMode.manual,
              constraints: const BoxConstraints(minHeight: 24),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              margin: const EdgeInsets.symmetric(horizontal: 12),
              child: widget.child,
            ),
          ),
        ),
      ),
    ),
  );
}
