import 'dart:async';
import 'dart:io';

class AppLogger {
  AppLogger(this.path);

  static const _maxBytes = 2 * 1024 * 1024;

  final String path;
  Future<void> _pending = Future.value();

  Future<void> info(String message) => _write('INFO', message);

  Future<void> error(String message, Object error, [StackTrace? stackTrace]) =>
      _write(
        'ERROR',
        '$message: $error${stackTrace == null ? '' : '\n$stackTrace'}',
      );

  Future<void> ensureExists() => _enqueue(() async {
    final file = File(path);
    await file.parent.create(recursive: true);
    if (!await file.exists()) await file.create();
  });

  Future<void> _write(String level, String message) => _enqueue(() async {
    final file = File(path);
    await file.parent.create(recursive: true);
    if (await file.exists() && await file.length() >= _maxBytes) {
      final rotated = File('$path.1');
      if (await rotated.exists()) await rotated.delete();
      await file.rename(rotated.path);
    }
    final timestamp = DateTime.now().toUtc().toIso8601String();
    await file.writeAsString(
      '$timestamp [$level] ${_sanitize(message)}\n',
      mode: FileMode.append,
      flush: true,
    );
  });

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _pending.then((_) => action()).catchError((_) {});
    _pending = next;
    return next;
  }

  String _sanitize(String value) => value
      .replaceAllMapped(
        RegExp(r'(session_token_code=)[^&#\s]+', caseSensitive: false),
        (match) => '${match[1]}<redacted>',
      )
      .replaceAllMapped(
        RegExp(
          r'((?:access|session|id|refresh)[_-]?token["\s:=]+)[^\s,&}\]]+',
          caseSensitive: false,
        ),
        (match) => '${match[1]}<redacted>',
      )
      .replaceAllMapped(
        RegExp(r'(authorization["\s:=]+)[^\r\n,]+', caseSensitive: false),
        (match) => '${match[1]}<redacted>',
      )
      .replaceAllMapped(
        RegExp(r'(cookie["\s:=]+)[^\r\n]+', caseSensitive: false),
        (match) => '${match[1]}<redacted>',
      );
}
