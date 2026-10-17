import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// A process-held OS file lock elects the owner; loopback carries activation
/// only. No launch arguments, paths, account data or library commands are sent.
/// The lock file is never unlinked: deleting it would permit two locked inodes.
final class DesktopSingleInstance {
  DesktopSingleInstance._(
    this._lock,
    this._server,
    this._nonce,
    this._onActivate,
  );

  final RandomAccessFile _lock;
  final ServerSocket _server;
  final String _nonce;
  final Future<void> Function() _onActivate;
  final _clients = <Socket>{};
  Future<void>? _activation;
  Future<void>? _closing;

  /// Null means the existing owner accepted activation. It never means that
  /// activation failed: all failures are closed, before core initialization.
  static Future<DesktopSingleInstance?> acquire({
    required Directory directory,
    required Future<void> Function() onActivate,
    Duration waitTimeout = const Duration(seconds: 5),
  }) async {
    await directory.create(recursive: true);
    final scope = await directory.resolveSymbolicLinks();
    final lock = await File('$scope/owner.lock').open(mode: FileMode.append);
    final descriptor = File('$scope/owner.json');
    final deadline = DateTime.now().add(waitTimeout);
    var held = false;
    var closed = false;
    try {
      while (!held) {
        try {
          await lock.lock(FileLock.exclusive);
          held = true;
        } on FileSystemException {
          if (await _requestActivation(descriptor)) {
            await lock.close();
            return null;
          }
          if (!DateTime.now().isBefore(deadline)) {
            throw const DesktopInstanceUnavailable();
          }
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final nonce = List.generate(
        32,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final owner = DesktopSingleInstance._(lock, server, nonce, onActivate);
      try {
        server.listen(owner._accept, onError: (Object _) {});
        await descriptor.writeAsString(
          jsonEncode({
            'protocol': 1,
            'pid': pid,
            'port': server.port,
            'nonce': nonce,
          }),
          flush: true,
        );
        return owner;
      } catch (_) {
        await owner.close();
        held = false;
        closed = true;
        rethrow;
      }
    } catch (_) {
      if (held) await lock.unlock();
      if (!closed) await lock.close();
      rethrow;
    }
  }

  static Future<bool> _requestActivation(File descriptor) async {
    Socket? socket;
    try {
      final bytes = BytesBuilder();
      await for (final chunk in descriptor.openRead(0, 4096)) {
        bytes.add(chunk);
      }
      final value = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (value is! Map<String, dynamic> ||
          value['protocol'] != 1 ||
          value['pid'] is! int ||
          (value['pid'] as int) <= 0 ||
          (value['pid'] as int) > 0xffffffff ||
          value['port'] is! int ||
          (value['port'] as int) < 1 ||
          (value['port'] as int) > 65535 ||
          value['nonce'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(value['nonce'] as String)) {
        return false;
      }
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        value['port'] as int,
        timeout: const Duration(milliseconds: 400),
      );
      if (Platform.isWindows) {
        // Transfer the launching process's foreground permission to the owner.
        // The only native capability crossed is permission to focus a window.
        final allow = ffi.DynamicLibrary.open('user32.dll')
            .lookupFunction<ffi.Int32 Function(ffi.Uint32), int Function(int)>(
              'AllowSetForegroundWindow',
            );
        allow(value['pid'] as int);
      }
      socket.write('ACTIVATE ${value['nonce']}\n');
      await socket.flush();
      return await _line(socket) == 'OK';
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  static Future<String> _line(Socket socket) async {
    final bytes = BytesBuilder();
    await for (final chunk in socket.timeout(const Duration(seconds: 2))) {
      if (bytes.length + chunk.length > 512) {
        throw const DesktopInstanceUnavailable();
      }
      bytes.add(chunk);
      final data = bytes.toBytes();
      final newline = data.indexOf(10);
      if (newline >= 0) {
        if (newline != data.length - 1) {
          throw const DesktopInstanceUnavailable();
        }
        return ascii.decode(data.sublist(0, newline));
      }
    }
    throw const DesktopInstanceUnavailable();
  }

  void _accept(Socket socket) {
    if (_closing != null || _clients.length >= 8) {
      socket.destroy();
      return;
    }
    _clients.add(socket);
    unawaited(() async {
      var accepted = false;
      try {
        accepted = await _line(socket) == 'ACTIVATE $_nonce';
      } catch (_) {
        // Malformed, slow or unauthenticated clients never activate the owner.
      }
      try {
        if (_closing != null) accepted = false;
        if (accepted) _activate();
        socket.write(accepted ? 'OK\n' : 'NO\n');
        await socket.flush();
        await socket.close();
      } catch (_) {
        // The requester may have exited; the primary remains the owner.
      } finally {
        _clients.remove(socket);
        socket.destroy();
      }
    }());
  }

  void _activate() {
    if (_activation != null || _closing != null) return;
    _activation = Future<void>.sync(_onActivate)
        .catchError((Object _) {
          // No incoming data or endpoint descriptor is included in diagnostics.
          stderr.writeln('NSOAlbum window activation was unavailable');
        })
        .whenComplete(() => _activation = null);
  }

  /// Called only after the application has closed its library and window.
  /// Abrupt process exit releases the OS lock without deleting any files.
  Future<void> close() => _closing ??= () async {
    await _server.close();
    for (final socket in _clients.toList()) {
      socket.destroy();
    }
    await _lock.unlock();
    await _lock.close();
  }();
}

final class DesktopInstanceUnavailable implements Exception {
  const DesktopInstanceUnavailable();
  @override
  String toString() => 'The existing application could not be activated';
}
