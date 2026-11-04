import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';

enum DeviceSyncSafError {
  busy,
  permissionDenied,
  windowFull,
  closed,
  timeout,
  invalidInput,
  unavailable,
}

final class DeviceSyncSafFailure extends StateError {
  DeviceSyncSafFailure(this.code) : super('Device exchange ${code.name}');
  final DeviceSyncSafError code;
}

/// Optional Android byte transport, independent of AppBackend and account state.
final class DeviceSyncSaf {
  DeviceSyncSaf({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('io.github.cypas.nsoalbum/device_sync_saf');

  final MethodChannel _channel;
  final _random = Random.secure();
  String? _operation;
  String? _session;
  String? _ownerToken;
  String? _pickerToken;
  int _epoch = 0;
  bool _pending = false;
  void Function()? _cancelPending;
  Future<void>? _ending;

  String _newToken() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<void> selectTree() async {
    if (_operation != null || _pending || _pickerToken != null) {
      throw DeviceSyncSafFailure(DeviceSyncSafError.busy);
    }
    final token = _newToken();
    _pickerToken = token;
    _ending = null;
    try {
      await _native<void>('selectTree', {'pickerToken': token});
    } finally {
      if (_pickerToken == token) _pickerToken = null;
    }
  }

  Future<T?> _native<T>(String method, [Map<String, Object>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (error) {
      throw DeviceSyncSafFailure(switch (error.code) {
        'BUSY' => DeviceSyncSafError.busy,
        'DIRECTORY_NOT_AUTHORIZED' => DeviceSyncSafError.permissionDenied,
        'WINDOW_FULL' => DeviceSyncSafError.windowFull,
        'OPERATION_CLOSED' => DeviceSyncSafError.closed,
        'TIMEOUT' => DeviceSyncSafError.timeout,
        'INVALID_SCOPE' || 'INVALID_BLOCK' => DeviceSyncSafError.invalidInput,
        _ => DeviceSyncSafError.unavailable,
      });
    } on MissingPluginException {
      throw DeviceSyncSafFailure(DeviceSyncSafError.unavailable);
    }
  }

  Future<void> openSession(String operationId, String sessionId) async {
    if (_operation != null || _pending || _pickerToken != null) {
      throw DeviceSyncSafFailure(DeviceSyncSafError.busy);
    }
    final valid = RegExp(r'^[0-9a-f]{32}$');
    if (!valid.hasMatch(operationId) || !valid.hasMatch(sessionId)) {
      throw ArgumentError('Invalid operation/session');
    }
    _operation = operationId;
    _session = sessionId;
    _ownerToken = _newToken();
    _ending = null;
    final epoch = _epoch;
    try {
      await _invoke<void>('openSession', {});
      if (epoch != _epoch) throw StateError('Operation closed');
    } catch (_) {
      if (epoch == _epoch) {
        _operation = null;
        _session = null;
        _ownerToken = null;
      }
      rethrow;
    }
  }

  Map<String, Object> get _scope {
    if (_operation == null || _session == null || _ownerToken == null) {
      throw StateError('Operation closed');
    }
    return {
      'operationId': _operation!,
      'sessionId': _session!,
      'ownerToken': _ownerToken!,
    };
  }

  Future<T?> _invoke<T>(String method, Map<String, Object> args) async {
    if (_pending) throw DeviceSyncSafFailure(DeviceSyncSafError.busy);
    final scope = _scope;
    final epoch = _epoch;
    _pending = true;
    final cancelled = Completer<T?>();
    _cancelPending = () => cancelled.completeError(
      DeviceSyncSafFailure(DeviceSyncSafError.closed),
    );
    try {
      final result = await Future.any<T?>([
        _native<T>(method, {...scope, ...args}),
        cancelled.future,
      ]);
      if (epoch != _epoch) {
        throw DeviceSyncSafFailure(DeviceSyncSafError.closed);
      }
      return result;
    } finally {
      if (epoch == _epoch) {
        _pending = false;
        _cancelPending = null;
      }
    }
  }

  Future<List<String>> listBlocks(String direction) async =>
      (await _invoke<List<Object?>>('listBlocks', {
        'direction': direction,
      }))!.cast<String>();

  Future<Uint8List> readBlock(String direction, String name) async =>
      (await _invoke<Uint8List>('readBlock', {
        'direction': direction,
        'name': name,
      }))!;

  Future<void> writeCiphertextBlock(String name, Uint8List bytes) =>
      _invoke<void>('writeCiphertextBlock', {'name': name, 'bytes': bytes});

  /// Retire at most eight sequential blocks through [name], only after the
  /// ordered ciphertext decoder accepted every block in that prefix.
  Future<void> acknowledgeBlock(String direction, String name) =>
      _invoke<void>('acknowledgeBlock', {'direction': direction, 'name': name});

  Future<void> _end(String method) {
    final ending = _ending;
    if (ending != null) return ending;
    final scope = _ownerToken != null
        ? _scope
        : _pickerToken != null
        ? <String, Object>{'pickerToken': _pickerToken!}
        : null;
    _epoch++;
    _operation = null;
    _session = null;
    _ownerToken = null;
    _pickerToken = null;
    _pending = false;
    _cancelPending?.call();
    _cancelPending = null;
    return _ending = scope == null
        ? Future<void>.value()
        : _native<void>(method, scope);
  }

  Future<void> close() => _end('close');

  Future<void> cancel() => _end('cancel');

  Future<void> revoke() async {
    await cancel();
    await _native<void>('revoke');
  }
}
