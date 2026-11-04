/// Scoped public Flutter VM extension flags. No private engine calls or user
/// settings are involved; even a partially applied set must be restored.
class GalleryFrameworkProfile {
  GalleryFrameworkProfile(this.invoke);
  final Future<Map<String, dynamic>> Function(
    String method,
    Map<String, String> arguments,
  )
  invoke;
  static const methods = {
    'ext.flutter.profileWidgetBuilds',
    'ext.flutter.profileRenderObjectLayouts',
    'ext.flutter.profileRenderObjectPaints',
  };
  final _previous = <String, bool>{};
  final summary = <String, Object>{
    'requested': true,
    'enabledCount': 0,
    'restored': false,
    'restoreFailures': 0,
  };

  bool _value(Map response) => switch (response['enabled']) {
    true || 'true' => true,
    false || 'false' => false,
    _ => throw StateError('Invalid framework flag response'),
  };

  Future<void> enable(Set<String> available) async {
    for (final method in methods.where(available.contains)) {
      final previous = _value(await invoke(method, {}));
      _previous[method] = previous;
      if (!_value(await invoke(method, {'enabled': 'true'}))) {
        throw StateError('Framework profiling was not enabled');
      }
      summary['enabledCount'] = (summary['enabledCount'] as int) + 1;
    }
    if (_previous.isEmpty) throw StateError('Framework profiling unavailable');
  }

  Future<void> restore() async {
    for (final entry in _previous.entries.toList().reversed) {
      try {
        final restored = _value(
          await invoke(entry.key, {'enabled': '${entry.value}'}),
        );
        if (restored != entry.value) {
          throw StateError('Framework flag restore failed');
        }
        _previous.remove(entry.key);
      } catch (_) {
        summary['restoreFailures'] = (summary['restoreFailures'] as int) + 1;
      }
    }
    summary['restored'] = _previous.isEmpty;
  }
}
