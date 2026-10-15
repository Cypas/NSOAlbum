/// Serializes native creation and disposal, including leaving during creation.
class WebResourceLifecycle {
  bool _active = true;
  Future<void>? _initialization;
  Future<void>? _cleanup;
  bool get active => _active;

  Future<void> initialize(Future<void> Function() allocate) =>
      _initialization ??= Future<void>.sync(allocate);

  Future<void> close(Future<void> Function() release) {
    _active = false;
    return _cleanup ??= () async {
      try {
        await _initialization;
      } catch (_) {
        // Even a partially constructed native view may own resources.
      }
      await release();
    }();
  }
}
