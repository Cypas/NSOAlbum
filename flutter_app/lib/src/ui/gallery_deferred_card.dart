import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'gallery_drag_loading.dart';
import 'gallery_perf.dart';

/// Keep the full subtree once admitted. Only newly encountered cards may be
/// lightweight, so moving again never strips an existing card's controls/state.
class GalleryDeferredCard extends StatefulWidget {
  const GalleryDeferredCard({
    super.key,
    this.enabled = true,
    required this.builder,
    required this.placeholderBuilder,
  });
  final bool enabled;
  final WidgetBuilder builder;
  final WidgetBuilder placeholderBuilder;

  @override
  State<GalleryDeferredCard> createState() => _GalleryDeferredCardState();
}

class _GalleryDeferredCardState extends State<GalleryDeferredCard> {
  GalleryDragLoadController? _controller;
  bool? _complete;
  bool _admitted = false;
  Widget? _content;

  bool _visible() {
    if (!mounted) return false;
    final box = context.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        box.size.isEmpty) {
      return false;
    }
    final rect = box.localToGlobal(Offset.zero) & box.size;
    var clip = Rect.largest;
    RenderObject? parent = box.parent;
    while (parent != null) {
      if (parent is RenderAbstractViewport && parent is RenderBox) {
        final viewport = parent as RenderBox;
        if (viewport.hasSize) {
          clip = clip.intersect(
            viewport.localToGlobal(Offset.zero) & viewport.size,
          );
        }
      }
      if (parent is RenderView) {
        clip = clip.intersect(Offset.zero & parent.size);
      }
      parent = parent.parent;
    }
    return rect.overlaps(clip) && !clip.isEmpty;
  }

  void _restore() {
    if (!mounted || _complete == true || _controller?.defer == true) return;
    setState(() => _admitted = true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = GalleryPreviewLoadScope.maybeOf(context);
    if (!identical(next, _controller)) {
      _controller?.cancelCard(this);
      _controller = next;
    }
    if (_complete == null) {
      _complete = !widget.enabled || next?.defer != true;
      if (_complete == false) {
        GalleryPerf.instance.increment(GalleryMetric.cardDeferred);
      }
    }
    if (!widget.enabled ||
        next == null ||
        !next.experiment.enabled ||
        next.experiment.mode == GalleryLoadMode.immediate) {
      _complete = true;
      next?.cancelCard(this);
    }
    if (_complete != true) {
      next?.requestCard(this, visible: _visible, restore: _restore);
    }
  }

  @override
  void didUpdateWidget(GalleryDeferredCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _content = null;
    if (!widget.enabled) {
      _complete = true;
      _controller?.cancelCard(this);
    }
  }

  @override
  void dispose() {
    if (_complete == false) {
      GalleryPerf.instance.increment(GalleryMetric.cardRestoreCancelled);
    }
    _controller?.cancelCard(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_complete != true && _admitted) {
      _admitted = false;
      if (_controller?.defer != true) {
        _complete = true;
        GalleryPerf.instance.increment(GalleryMetric.cardRestored);
      } else {
        _controller?.requestCard(this, visible: _visible, restore: _restore);
      }
    }
    return _complete == true
        ? _content ??= widget.builder(context)
        : widget.placeholderBuilder(context);
  }
}
