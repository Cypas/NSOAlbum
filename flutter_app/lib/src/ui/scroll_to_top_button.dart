import 'dart:async';

import 'package:flutter/material.dart';

import 'gallery_return_layout.dart';

final _returnOperations = Expando<Future<void>>('gallery-return-to-top');

Future<void> scrollGalleryToTop(ScrollController controller) {
  final active = _returnOperations[controller];
  if (active != null) return active;
  if (!controller.hasClients) return Future<void>.value();

  final completion = Completer<void>();
  _returnOperations[controller] = completion.future;
  unawaited(() async {
    try {
      await _returnToTop(controller);
      completion.complete();
    } catch (error, stack) {
      completion.completeError(error, stack);
    } finally {
      _returnOperations[controller] = null;
    }
  }());
  return completion.future;
}

Future<void> _returnToTop(ScrollController controller) async {
  final positions = controller.positions.toList(growable: false);
  if (positions.length != 1) {
    await controller.animateTo(
      0,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
    );
    return;
  }

  final position = positions.single;
  final viewport = position.viewportDimension;
  final distance = position.pixels - position.minScrollExtent;
  if (viewport > 0 && distance > viewport * 2) {
    GalleryReturnLayout.reset(controller);
    // Do not animate through all intervening rows and build their cards.
    position.jumpTo(
      (position.minScrollExtent + viewport)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble(),
    );
    var interrupted = false;
    void onScrollActivity() {
      if (position.isScrollingNotifier.value) interrupted = true;
    }

    position.isScrollingNotifier.addListener(onScrollActivity);
    try {
      // The near-top sliver must complete layout before the short animation.
      // A drag during this gap owns the scroll and must not be overridden.
      await WidgetsBinding.instance.endOfFrame;
      if (interrupted || !_stillAttached(controller, position)) return;
    } finally {
      position.isScrollingNotifier.removeListener(onScrollActivity);
    }
  }
  if (!_stillAttached(controller, position)) return;
  await position.animateTo(
    0,
    duration: const Duration(milliseconds: 360),
    curve: Curves.easeOutCubic,
  );
}

bool _stillAttached(ScrollController controller, ScrollPosition position) =>
    controller.hasClients &&
    controller.positions.contains(position) &&
    position.context.storageContext.mounted;

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
                onPressed: () => scrollGalleryToTop(controller),
                icon: const Icon(Icons.keyboard_arrow_up_rounded),
              ),
            ),
          ),
        ),
      );
    },
  );
}
