import 'dart:async';
import 'dart:typed_data';

import '../backend/account_tool_lifecycle.dart';
import '../backend/nintendo_account_tools_backend.dart';
import '../backend/account_tool_requests.dart';

typedef _ImageKey = (String, String, String, String);

/// Presentation bytes only. Rust remains responsible for downloads and URLs.
class AccountToolImages {
  AccountToolImages._(this.backend);
  final NintendoAccountToolsBackend backend;
  static final _instances = Expando<AccountToolImages>();
  static AccountToolImages of(NintendoAccountToolsBackend backend) =>
      _instances[backend] ??= AccountToolImages._(backend);

  final _bytes = <_ImageKey, Uint8List>{};
  final _pending = <_ImageKey, _PendingImage>{};
  final _accounts = <String, AccountCleanupRegistration>{};
  int _size = 0;

  _ImageKey _avatarKey(String account, String friend, String? url) =>
      ('avatar', account, friend, url ?? '');

  Uint8List? avatar(String account, String friend, String? url) =>
      _peek(_avatarKey(account, friend, url));

  AccountImageLease loadAvatar(String account, String friend, String? url) =>
      _load(
        _avatarKey(account, friend, url),
        account,
        (id) => backend.loadNintendoFriendAvatar(account, friend, id),
      );

  Uint8List? game(String name, String url) => _peek(('game', '', name, url));

  AccountImageLease loadGame(String account, String name, String url) =>
      _load(('game', '', name, url), account, (id) async {
        final source = backend;
        if (source is! NintendoGameImageBackend) return Uint8List(0);
        return (source as NintendoGameImageBackend).loadNintendoGameImage(
          account,
          name,
          id,
        );
      });

  Uint8List? _peek(_ImageKey key) {
    final value = _bytes.remove(key);
    if (value != null) _bytes[key] = value;
    return value;
  }

  AccountImageLease _load(
    _ImageKey key,
    String account,
    Future<Uint8List> Function(String) download,
  ) {
    if (backend case final NintendoAccountToolLifecycleBackend lifecycle) {
      if (lifecycle.accountToolLifecycle.isRemoved(account)) {
        return AccountImageLease._(Future.value(Uint8List(0)), () {});
      }
      _accounts.putIfAbsent(
        account,
        () => lifecycle.accountToolLifecycle.registerCleanup(account, () async {
          for (final key
              in _bytes.keys
                  .where((key) => key.$1 == 'avatar' && key.$2 == account)
                  .toList()) {
            _size -= _bytes.remove(key)!.length;
          }
          final pending = _pending.entries
              .where((entry) => entry.value.account == account)
              .toList();
          for (final entry in pending) {
            _pending.remove(entry.key);
            await cancelAccountToolQuietly(backend, entry.value.operation);
          }
          _accounts.remove(account)?.remove();
        }),
      );
    }
    final cached = _peek(key);
    if (cached != null) {
      return AccountImageLease._(Future.value(cached), () {});
    }
    for (final old
        in _pending.entries
            .where(
              (entry) =>
                  entry.key.$1 == key.$1 &&
                  entry.key.$2 == key.$2 &&
                  entry.key.$3 == key.$3 &&
                  entry.key.$4 != key.$4,
            )
            .toList()) {
      _pending.remove(old.key);
      unawaited(cancelAccountToolQuietly(backend, old.value.operation));
    }
    var pending = _pending[key];
    if (pending == null) {
      final operation = accountToolOperationId('${key.$1}-image');
      final created = _PendingImage(account, operation);
      pending = created;
      _pending[key] = created;
      created.future = () async {
        try {
          final result = await download(operation);
          if (identical(_pending[key], created) &&
              result.isNotEmpty &&
              result.length <= 4 * 1024 * 1024) {
            // Retire superseded URLs for this identity.
            for (final old
                in _bytes.keys
                    .where(
                      (old) =>
                          old.$1 == key.$1 &&
                          old.$2 == key.$2 &&
                          old.$3 == key.$3,
                    )
                    .toList()) {
              _size -= _bytes.remove(old)!.length;
            }
            while (_bytes.isNotEmpty &&
                (_bytes.length >= 128 ||
                    _size + result.length > 16 * 1024 * 1024)) {
              _size -= _bytes.remove(_bytes.keys.first)!.length;
            }
            _bytes[key] = result;
            _size += result.length;
          }
          return result;
        } finally {
          if (identical(_pending[key], created)) _pending.remove(key);
          unawaited(cancelAccountToolQuietly(backend, operation));
        }
      }();
    }
    final active = pending;
    active.readers++;
    return AccountImageLease._(active.future, () {
      active.readers--;
      if (active.readers == 0 && identical(_pending[key], active)) {
        _pending.remove(key);
        unawaited(cancelAccountToolQuietly(backend, active.operation));
      }
    });
  }
}

class _PendingImage {
  _PendingImage(this.account, this.operation);
  final String account;
  final String operation;
  late Future<Uint8List> future;
  int readers = 0;
}

class AccountImageLease {
  AccountImageLease._(this.future, this._release);
  final Future<Uint8List> future;
  void Function()? _release;
  void release() {
    _release?.call();
    _release = null;
  }
}
