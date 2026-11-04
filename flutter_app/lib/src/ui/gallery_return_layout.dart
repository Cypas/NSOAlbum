import 'package:flutter/widgets.dart';

/// Variable-height slivers may realize every preceding child when jumping
/// backwards. A gallery can reset only its render-child layout before a distant
/// return, retaining the Scrollable, query, data and current selection.
class GalleryReturnLayout {
  GalleryReturnLayout._();

  static final _bindings = Expando<_GalleryLayoutBinding>(
    'gallery-return-layout',
  );

  static VoidCallback bind(
    ScrollController controller,
    VoidCallback resetLayout,
  ) {
    final binding = _GalleryLayoutBinding(resetLayout);
    _bindings[controller] = binding;
    return () {
      if (identical(_bindings[controller], binding)) {
        _bindings[controller] = null;
      }
    };
  }

  static void reset(ScrollController controller) =>
      _bindings[controller]?.reset();
}

class _GalleryLayoutBinding {
  const _GalleryLayoutBinding(this.reset);
  final VoidCallback reset;
}
