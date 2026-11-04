import 'package:flutter/foundation.dart';

/// Optional invalidations for already-open account tools, not sync events.
abstract interface class NintendoAccountToolLifecycleBackend {
  AccountToolLifecycle get accountToolLifecycle;
}

class AccountToolLifecycle extends ChangeNotifier {
  final _removed = <String>{};
  final _cleanups = <Object, (String, Future<void> Function())>{};
  AccountCleanupRegistration registerCleanup(
    String accountId,
    Future<void> Function() cleanup,
  ) {
    final key = Object();
    _cleanups[key] = (accountId, cleanup);
    return AccountCleanupRegistration._(() => _cleanups.remove(key));
  }

  Future<void> invalidateAndWait(Set<String> accountIds) async {
    _removed.addAll(accountIds);
    notifyListeners();
    final pending = [
      for (final cleanup in _cleanups.values.toList())
        if (accountIds.contains(cleanup.$1)) Future<void>.sync(cleanup.$2),
    ];
    await Future.wait(pending);
  }

  bool isRemoved(String accountId) => _removed.contains(accountId);
  void removeAccount(String accountId) {
    _removed.add(accountId);
    notifyListeners();
  }

  void accountAvailable(String accountId) {
    _removed.remove(accountId);
    notifyListeners();
  }

  void networkChanged() => notifyListeners();
}

class AccountCleanupRegistration {
  AccountCleanupRegistration._(this._remove);
  void Function()? _remove;
  void remove() {
    _remove?.call();
    _remove = null;
  }
}
