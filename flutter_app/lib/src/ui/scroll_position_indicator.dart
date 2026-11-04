import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

class ScrollPositionIndicator extends StatefulWidget {
  const ScrollPositionIndicator({
    super.key,
    required this.controller,
    required this.loadedCount,
    this.totalCount,
    this.counting = false,
    this.right = 28,
    this.bottom = 24,
  });

  final ScrollController controller;
  final int loadedCount;
  final int? totalCount;
  final bool counting;
  final double right;
  final double bottom;

  @override
  State<ScrollPositionIndicator> createState() =>
      _ScrollPositionIndicatorState();
}

class _ScrollPositionIndicatorState extends State<ScrollPositionIndicator> {
  Timer? _hideTimer;
  bool _visible = false;
  double? _lastOffset;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant ScrollPositionIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
      _lastOffset = null;
    }
  }

  void _onScroll() {
    if (!widget.controller.hasClients) return;
    final offset = widget.controller.position.pixels;
    if (_lastOffset == offset) return;
    _lastOffset = offset;
    _hideTimer?.cancel();
    setState(() => _visible = true);
    _hideTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  String _label(BuildContext context) {
    final total = widget.totalCount;
    if (total == null) {
      return context.l10n.select(
        zh: '已加载 ${widget.loadedCount} 项${widget.counting ? ' · 正在统计' : ''}',
        en: 'Loaded ${widget.loadedCount}${widget.counting ? ' · Counting' : ''}',
      );
    }
    if (!widget.controller.hasClients ||
        !widget.controller.position.hasContentDimensions ||
        total == 0 ||
        widget.controller.position.maxScrollExtent <= 0) {
      return context.l10n.select(zh: '共 $total 项', en: '$total items');
    }
    final position = widget.controller.position;
    final progress = (position.pixels / position.maxScrollExtent).clamp(
      0.0,
      1.0,
    );
    final current = (progress * (total - 1)).round() + 1;
    return context.l10n.select(
      zh: '约第 $current 项 / 共 $total 项',
      en: 'About $current / $total',
    );
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Positioned(
    right: widget.right,
    bottom: widget.bottom,
    child: IgnorePointer(
      child: AnimatedOpacity(
        key: const Key('scroll-position-indicator'),
        opacity: _visible ? 1 : 0,
        duration: const Duration(milliseconds: 140),
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          elevation: 5,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Text(
              _label(context),
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ),
      ),
    ),
  );
}
