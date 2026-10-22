import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/account_tool_lifecycle.dart';
import 'package:squid_album/src/backend/nintendo_account_tools_backend.dart';
import 'package:squid_album/src/state/account_tool_images.dart';

void main() {
  test(
    'shared game images coalesce readers and survive a different account',
    () async {
      final backend = _Images();
      final cache = AccountToolImages.of(backend);
      final first = cache.loadGame('a', 'Game', 'url');
      final second = cache.loadGame('b', 'Game', 'url');
      expect(backend.downloads, ['game:a:Game']);
      first.release();
      expect(backend.cancelled, isEmpty);
      backend.pending.single.complete(Uint8List.fromList([1, 2]));
      expect(await second.future, [1, 2]);
      second.release();
      expect(cache.game('Game', 'url'), [1, 2]);
      final cached = cache.loadGame('c', 'Game', 'url');
      expect(await cached.future, [1, 2]);
      expect(backend.downloads, hasLength(1));
      cached.release();
    },
  );

  test('a late old image URL cannot replace a newer game image', () async {
    final backend = _Images();
    final cache = AccountToolImages.of(backend);
    final old = cache.loadGame('a', 'Game', 'old');
    final current = cache.loadGame('a', 'Game', 'new');
    backend.pending[1].complete(Uint8List.fromList([2]));
    await current.future;
    backend.pending[0].complete(Uint8List.fromList([1]));
    await old.future;
    expect(cache.game('Game', 'new'), [2]);
    expect(cache.game('Game', 'old'), isNull);
    old.release();
    current.release();
  });

  test(
    'avatars remain account specific and removal rejects late cache writes',
    () async {
      final backend = _Images();
      final cache = AccountToolImages.of(backend);
      final first = cache.loadAvatar('a', 'friend', 'url');
      final other = cache.loadAvatar('b', 'friend', 'url');
      backend.pending[1].complete(Uint8List.fromList([2]));
      await other.future;
      await backend.accountToolLifecycle.invalidateAndWait({'a'});
      backend.pending[0].complete(Uint8List.fromList([1]));
      await first.future;
      expect(cache.avatar('a', 'friend', 'url'), isNull);
      expect(cache.avatar('b', 'friend', 'url'), [2]);
      first.release();
      other.release();
    },
  );

  test(
    'the last reader cancels a download and a failed image can retry',
    () async {
      final backend = _Images();
      final cache = AccountToolImages.of(backend);
      final first = cache.loadGame('a', 'Game', 'url');
      final failed = expectLater(first.future, throwsStateError);
      first.release();
      expect(backend.cancelled, hasLength(1));
      backend.pending[0].completeError(StateError('cancelled'));
      await failed;
      final retry = cache.loadGame('a', 'Game', 'url');
      backend.pending[1].complete(Uint8List.fromList([3]));
      expect(await retry.future, [3]);
      retry.release();
    },
  );
}

class _Images
    implements
        NintendoAccountToolsBackend,
        NintendoGameImageBackend,
        NintendoAccountToolLifecycleBackend {
  final downloads = <String>[];
  final pending = <Completer<Uint8List>>[];
  final cancelled = <String>[];
  @override
  final accountToolLifecycle = AccountToolLifecycle();
  Future<Uint8List> _load(String key) {
    downloads.add(key);
    final result = Completer<Uint8List>();
    pending.add(result);
    return result.future;
  }

  @override
  Future<Uint8List> loadNintendoGameImage(
    String accountId,
    String gameName,
    String operationId,
  ) => _load('game:$accountId:$gameName');
  @override
  Future<Uint8List> loadNintendoFriendAvatar(
    String accountId,
    String friendId,
    String operationId,
  ) => _load('avatar:$accountId:$friendId');
  @override
  Future<void> cancelAccountToolOperation(String operationId) async =>
      cancelled.add(operationId);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected image operation');
}
