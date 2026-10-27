import 'package:flutter/material.dart';

class ScrollToTopButton extends StatelessWidget {
  const ScrollToTopButton({
    super.key,
    required this.controller,
    required this.tooltip,
  });

  final ScrollController controller;
  final String tooltip;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final visible = controller.hasClients && controller.position.pixels > 360;
      return IgnorePointer(
        ignoring: !visible,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0, .35),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              elevation: 5,
              shadowColor: Theme.of(context).colorScheme.shadow
                  .withValues(alpha: .22),
              shape: const StadiumBorder(),
              child: IconButton(
                tooltip: tooltip,
                onPressed: () => controller.animateTo(
                  0,
                  duration: const Duration(milliseconds: 360),
                  curve: Curves.easeOutCubic,
                ),
                icon: const Icon(Icons.keyboard_arrow_up_rounded),
              ),
            ),
          ),
        ),
      );
    },
  );
}
