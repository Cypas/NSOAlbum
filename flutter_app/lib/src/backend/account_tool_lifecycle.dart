import 'package:flutter/foundation.dart';

/// Optional invalidations for already-open account tools, not sync events.
abstract interface class NintendoAccountToolLifecycleBackend {
  AccountToolLifecycle get accountToolLifecycle;
}

class AccountToolLifecycle extends ChangeNotifier {
  final _removed = <String>{};
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
