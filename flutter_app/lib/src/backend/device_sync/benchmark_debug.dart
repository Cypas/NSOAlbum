part of 'startup_lifecycle.dart';

/// Narrow seam for the explicitly enabled standalone Debug benchmark only.
extension DeviceSyncBenchmarkDebug on DeviceSyncSession {
  void _admitBenchmark() {
    if (!kDebugMode || !const bool.fromEnvironment('DEVICE_SYNC_REAL_NOOP')) {
      throw const DeviceSyncBusy();
    }
    _admit();
  }

  Future<bool> benchmarkRequireNoop(String binding) {
    _admitBenchmark();
    return _act(
      () => _command(
        () => native.deviceSyncBenchmarkRequireNoop(
          endpoint: _endpoint,
          binding: binding,
        ),
      ),
    );
  }

  Future<String?> benchmarkMetrics() async {
    _admitBenchmark();
    return native.deviceSyncBenchmarkMetrics(endpoint: _endpoint);
  }
}
