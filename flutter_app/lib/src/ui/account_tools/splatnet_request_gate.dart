/// One page may prepare or refresh only one game-web session at a time.
class SplatNetRequestGate {
  bool _busy = false;
  bool get busy => _busy;

  Future<void> run(Future<void> Function() request) async {
    if (_busy) return;
    _busy = true;
    try {
      await request();
    } finally {
      _busy = false;
    }
  }
}
