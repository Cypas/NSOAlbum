import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'desktop_fluid_scroll_physics.dart';

enum GalleryLoadMode { immediate, settled }

enum GalleryWorkAdmission { all, visible, paused }

enum GalleryDragPhase { idle, moving, settling }

/// Scheduling policy only; no settings or media state are changed.
class GalleryLoadExperiment extends ChangeNotifier {
  GalleryLoadExperiment({required this.enabled});

  static const available =
      kDebugMode &&
      bool.fromEnvironment('NSO_GALLERY_PERF', defaultValue: false);
  static final instance = GalleryLoadExperiment(enabled: true)
    .._mode = GalleryLoadMode.settled;
  final bool enabled;
  final admission = ValueNotifier(GalleryWorkAdmission.all);
  final Set<GalleryDragLoadController> _controllers = {};
  GalleryLoadMode _mode = GalleryLoadMode.immediate;
  GalleryLoadMode get mode => _mode;
  VoidCallback? onModeChanging;
  void Function(GalleryDragPhase)? onPhase;

  void setMode(GalleryLoadMode value) {
    if (!enabled || value == _mode) return;
    onModeChanging?.call();
    for (final controller in _controllers.toList()) {
      controller.end();
    }
    _mode = value;
    // A released thumb has no end() notification. Publish the installed mode
    // to card scopes too, so dormant B placeholders cannot survive in A.
    for (final controller in _controllers.toList()) {
      controller._publish();
    }
    _refreshAdmission();
    notifyListeners();
  }

  void _refreshAdmission() {
    final held = _controllers.where((controller) => controller.held);
    admission.value =
        !enabled || _mode == GalleryLoadMode.immediate || held.isEmpty
        ? GalleryWorkAdmission.all
        : held.any((controller) => controller.moving)
        ? GalleryWorkAdmission.paused
        : GalleryWorkAdmission.visible;
  }
}

class GalleryDragLoadController extends ChangeNotifier {
  GalleryDragLoadController(this.experiment, {this.cardsPerFrame = 3})
    : assert(cardsPerFrame > 0) {
    experiment._controllers.add(this);
  }

  final GalleryLoadExperiment experiment;
  final int cardsPerFrame;
  Timer? _timer;
  bool held = false;
  bool moving = false;
  bool hasMoved = false;
  bool _disposed = false;
  final _cards = <Object, ({bool Function() visible, VoidCallback restore})>{};
  bool _cardFrameScheduled = false;

  /// Pending widgets own these tickets; disposal cancels without hydration.
  /// Drain only visible entries, bounded per frame. Cache-extent entries wait for
  /// viewport movement instead of scheduling an endless stream of idle frames.
  void requestCard(
    Object owner, {
    required bool Function() visible,
    required VoidCallback restore,
  }) {
    if (_disposed) return;
    _cards[owner] = (visible: visible, restore: restore);
    _scheduleCardFrame();
  }

  void cancelCard(Object owner) => _cards.remove(owner);

  void viewportChanged() => _scheduleCardFrame();

  void _scheduleCardFrame() {
    if (_disposed || defer || _cardFrameScheduled || _cards.isEmpty) return;
    _cardFrameScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _cardFrameScheduled = false;
      if (_disposed || defer) return;
      for (
        var restored = 0;
        restored < cardsPerFrame && !_disposed && !defer;
        restored++
      ) {
        Object? next;
        for (final entry in _cards.entries) {
          if (entry.value.visible()) {
            next = entry.key;
            break;
          }
        }
        if (next == null) return;
        _cards.remove(next)?.restore();
      }
      _scheduleCardFrame();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  bool get defer =>
      held &&
      moving &&
      experiment.enabled &&
      experiment.mode == GalleryLoadMode.settled;

  void begin() {
    if (_disposed) return;
    held = true;
    hasMoved = false;
    // Merely pressing the thumb does not delay work.
  }

  void moved({bool settle = true, VoidCallback? onSettled}) {
    if (_disposed || !held) return;
    _timer?.cancel();
    final changed = !moving;
    moving = true;
    hasMoved = true;
    experiment.onPhase?.call(GalleryDragPhase.moving);
    _publish(notify: changed);
    // Driven wheel animations must finish before the quiet-period timer starts.
    if (!settle) return;
    _timer = Timer(const Duration(milliseconds: 50), () {
      if (_disposed || !held) return;
      if (onSettled != null) {
        onSettled();
        return;
      }
      moving = false;
      experiment.onPhase?.call(GalleryDragPhase.settling);
      _publish();
    });
  }

  void end({bool notify = true}) {
    _timer?.cancel();
    _timer = null;
    if (_disposed || !held) return;
    held = moving = hasMoved = false;
    experiment.onPhase?.call(GalleryDragPhase.idle);
    _publish(notify: notify);
  }

  void _publish({bool notify = true}) {
    experiment._refreshAdmission();
    _scheduleCardFrame();
    if (notify) notifyListeners();
  }

  @override
  void dispose() {
    end();
    _disposed = true;
    _cards.clear();
    experiment._controllers.remove(this);
    experiment._refreshAdmission();
    super.dispose();
  }
}

class GalleryPreviewLoadScope
    extends InheritedNotifier<GalleryDragLoadController> {
  const GalleryPreviewLoadScope({
    super.key,
    required GalleryDragLoadController controller,
    required super.child,
  }) : super(notifier: controller);

  static GalleryDragLoadController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<GalleryPreviewLoadScope>()
      ?.notifier;
}

/// Uses the unmodified Material Scrollbar and its actual painted thumb hit test.
class GalleryDragLoadRegion extends StatefulWidget {
  const GalleryDragLoadRegion({
    super.key,
    required this.controller,
    required this.child,
    this.experiment,
    this.touchDragging = false,
    this.cardsPerFrame = 3,
    this.showScrollbar = true,
  });
  final ScrollController controller;
  final Widget child;
  final GalleryLoadExperiment? experiment;
  final bool touchDragging;
  final int cardsPerFrame;
  final bool showScrollbar;

  @override
  State<GalleryDragLoadRegion> createState() => _GalleryDragLoadRegionState();
}

class _GalleryDragLoadRegionState extends State<GalleryDragLoadRegion>
    with WidgetsBindingObserver {
  final _scrollbarKey = GlobalKey();
  late GalleryDragLoadController _drag;
  int? _pointer;
  double? _lastOffset;
  ScrollPosition? _wheelPosition;

  @override
  void initState() {
    super.initState();
    _drag = GalleryDragLoadController(
      widget.experiment ?? GalleryLoadExperiment.instance,
      cardsPerFrame: widget.cardsPerFrame,
    );
    widget.controller.addListener(_onScroll);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(GalleryDragLoadRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _end();
      oldWidget.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
    }
    if (oldWidget.experiment != widget.experiment ||
        oldWidget.cardsPerFrame != widget.cardsPerFrame) {
      _end();
      _drag.dispose();
      _drag = GalleryDragLoadController(
        widget.experiment ?? GalleryLoadExperiment.instance,
        cardsPerFrame: widget.cardsPerFrame,
      );
    }
  }

  void _down(PointerDownEvent event) {
    if (_wheelPosition != null) _end();
    if (_pointer != null || !widget.controller.hasClients) {
      return;
    }
    if (widget.touchDragging &&
        (event.kind == PointerDeviceKind.touch ||
            event.kind == PointerDeviceKind.stylus)) {
      _pointer = event.pointer;
      _lastOffset = widget.controller.offset;
      _drag.begin();
      return;
    }
    if (event.kind != PointerDeviceKind.mouse ||
        event.buttons != kPrimaryMouseButton ||
        !widget.showScrollbar) {
      return;
    }
    Element? paintedThumb;
    void visit(Element element) {
      if (paintedThumb != null) return;
      if (element.widget case CustomPaint(
        foregroundPainter: ScrollbarPainter(),
      )) {
        paintedThumb = element;
      } else {
        element.visitChildren(visit);
      }
    }

    final context = _scrollbarKey.currentContext;
    if (context is! Element) return;
    context.visitChildren(visit);
    final render = paintedThumb?.findRenderObject();
    final painter = (paintedThumb?.widget as CustomPaint?)?.foregroundPainter;
    if (painter is! ScrollbarPainter ||
        render is! RenderBox ||
        !painter.hitTestOnlyThumbInteractive(
          render.globalToLocal(event.position),
          event.kind,
        )) {
      return;
    }
    _pointer = event.pointer;
    _lastOffset = widget.controller.offset;
    _drag.begin();
  }

  void _onScroll() {
    if (!widget.controller.hasClients) return;
    if (_pointer == null) {
      if (_wheelPosition != null) {
        _wheelChanged();
        return;
      }
      _drag.viewportChanged();
      return;
    }
    final offset = widget.controller.offset;
    if (_lastOffset == offset) return;
    _lastOffset = offset;
    _drag.moved();
  }

  void _end({bool notify = true}) {
    _wheelPosition?.isScrollingNotifier.removeListener(_wheelChanged);
    _wheelPosition = null;
    _pointer = null;
    _lastOffset = null;
    _drag.end(notify: notify);
  }

  bool _wheel(DesktopWheelScrollNotification notification) {
    if (notification.detached) {
      if (identical(_wheelPosition, notification.position)) {
        // Scrollable can replace a position during dependency/physics builds.
        // Its predecessor's notifier may still say "scrolling" when disposed.
        _end(notify: false);
      }
      return false;
    }
    if (!widget.controller.hasClients ||
        widget.controller.positions.length != 1 ||
        !identical(notification.position, widget.controller.position)) {
      return false;
    }
    if (!notification.wheel) {
      if (_wheelPosition != null) _end();
      return false;
    }
    if (_pointer != null) return false;
    if (!identical(_wheelPosition, notification.position)) {
      _wheelPosition?.isScrollingNotifier.removeListener(_wheelChanged);
      _wheelPosition = notification.position;
      _wheelPosition!.isScrollingNotifier.addListener(_wheelChanged);
    }
    if (!_drag.held) _drag.begin();
    _wheelChanged();
    return false;
  }

  void _wheelChanged() {
    final position = _wheelPosition;
    if (position == null) return;
    _drag.moved(settle: !position.isScrollingNotifier.value, onSettled: _end);
  }

  void _up(PointerEvent event) {
    if (event.pointer == _pointer) _end();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _end();
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.state == ViewFocusState.unfocused) _end();
  }

  @override
  void deactivate() {
    // Release cache admission immediately without rebuilding the inherited
    // scope that is being removed by the current build.
    _end(notify: false);
    super.deactivate();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    WidgetsBinding.instance.removeObserver(this);
    _drag.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GalleryPreviewLoadScope(
    controller: _drag,
    child: NotificationListener<DesktopWheelScrollNotification>(
      onNotification: _wheel,
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          _drag.viewportChanged();
          return false;
        },
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: Listener(
            onPointerDown: _down,
            onPointerUp: _up,
            onPointerCancel: _up,
            child: widget.showScrollbar
                ? Scrollbar(
                    key: _scrollbarKey,
                    controller: widget.controller,
                    child: widget.child,
                  )
                : widget.child,
          ),
        ),
      ),
    ),
  );
}

/// Reuses decoded images without asking an encoded memory hit to decode while
/// the thumb is moving. Already displayed images remain mounted.
class GalleryDeferredImage extends StatefulWidget {
  const GalleryDeferredImage({
    super.key,
    required this.bytes,
    this.cacheWidth,
    required this.placeholder,
    required this.builder,
  });
  final Uint8List bytes;
  final int? cacheWidth;
  final Widget placeholder;
  final Widget Function() builder;
  @override
  State<GalleryDeferredImage> createState() => _GalleryDeferredImageState();
}

class _GalleryDeferredImageState extends State<GalleryDeferredImage> {
  Uint8List? _displayed;
  Uint8List? _checked;
  bool _decoded = false;
  Widget? _shown;

  void _checkDecoded() {
    if (identical(_checked, widget.bytes)) return;
    final bytes = _checked = widget.bytes;
    _decoded = false;
    final provider = ResizeImage.resizeIfNeeded(
      widget.cacheWidth,
      null,
      MemoryImage(bytes),
    );
    provider.obtainKey(ImageConfiguration.empty).then((key) {
      if (!mounted || !identical(bytes, widget.bytes)) return;
      final status = PaintingBinding.instance.imageCache.statusForKey(key);
      final ready = !status.pending && (status.keepAlive || status.live);
      if (ready) {
        // obtainKey is synchronous for MemoryImage; avoid setState during build.
        _decoded = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = GalleryPreviewLoadScope.maybeOf(context);
    if (controller?.defer != true || identical(_displayed, widget.bytes)) {
      _displayed = widget.bytes;
      return _shown = widget.builder();
    }
    if (_shown != null) return _shown!;
    _checkDecoded();
    if (_decoded) {
      _displayed = widget.bytes;
      return _shown = widget.builder();
    }
    return widget.placeholder;
  }
}
