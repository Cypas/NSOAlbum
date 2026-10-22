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
        collapseRepeatedAsyncSuspension(
          '$message: $error${stackTrace == null ? '' : '\n$stackTrace'}',
        ),
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
    final timestamp = formatRuntimeLogTimestamp(DateTime.now());
    await file.writeAsString(
      '$timestamp [$level] ${sanitizeDiagnostic(message)}\n',
      mode: FileMode.append,
      flush: true,
    );
  });

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _pending.then((_) => action()).catchError((_) {});
    _pending = next;
    return next;
  }
}

/// Local wall time with seconds and an explicit offset, including UTC systems.
String formatRuntimeLogTimestamp(DateTime value) {
  final local = value.toLocal();
  final offset = local.timeZoneOffset;
  final minutes = offset.inMinutes.abs();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${local.year.toString().padLeft(4, '0')}-'
      '${two(local.month)}-${two(local.day)}T'
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}'
      '${offset.isNegative ? '-' : '+'}${two(minutes ~/ 60)}:'
      '${two(minutes % 60)}';
}

/// Shared by log writes, viewing, copying and diagnostic error panels.
String sanitizeDiagnostic(String value) => value
    .replaceAllMapped(
      RegExp(
        r'''[a-z][a-z0-9+.-]*://(?:\[[^\]\s]*\]|[^\s<>"\])}])+''',
        caseSensitive: false,
      ),
      (match) {
        final uri = Uri.tryParse(match[0]!);
        if (uri == null) return '<redacted-url>';
        if (const ['http', 'https', 'ws', 'wss'].contains(uri.scheme) &&
            const [
              'localhost',
              '127.0.0.1',
              '::1',
              '[::1]',
            ].contains(uri.host) &&
            uri.path.isNotEmpty &&
            uri.path != '/') {
          return '<redacted-local-url>';
        }
        return uri
            .replace(userInfo: '', query: '', fragment: '')
            .toString()
            .replaceAll(RegExp(r'[?#]+$'), '');
      },
    )
    .replaceAll(
      RegExp(r'''(?<![A-Za-z0-9+.-])[A-Za-z]:[\\/][^\s"<>]*'''),
      '<redacted-path>',
    )
    .replaceAll(
      RegExp(r'/(?:data/user|storage|home|Users|private|tmp)/[^\s"<>]*'),
      '<redacted-path>',
    )
    .replaceAll(
      RegExp(r'\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'),
      '<redacted-jwt>',
    )
    .replaceAllMapped(
      RegExp(r'(session_token_code=)[^&#\s]+', caseSensitive: false),
      (match) => '${match[1]}<redacted>',
    )
    .replaceAllMapped(
      RegExp(
        r'(?<![A-Za-z0-9_./])((?:(?:access|session|id|refresh|bullet|game[_-]?web)[_-]?token|gtoken|token)["\s:=]+)[^\s,&}\]]+',
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

String collapseRepeatedAsyncSuspension(String value) {
  final lines = value.split('\n');
  final output = <String>[];
  var repeated = 0;
  void flush() {
    if (repeated == 0) return;
    output.add(
      repeated == 1
          ? '<asynchronous suspension>'
          : '<asynchronous suspension> (repeated $repeated times)',
    );
    repeated = 0;
  }

  for (final line in lines) {
    if (line.trim() == '<asynchronous suspension>') {
      repeated += 1;
    } else {
      flush();
      output.add(line);
    }
  }
  flush();
  return output.join('\n');
}
