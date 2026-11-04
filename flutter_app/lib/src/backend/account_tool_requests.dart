import 'nintendo_account_tools_backend.dart';

int _operationSequence = 0;

String accountToolOperationId(String kind) =>
    '$kind-${DateTime.now().microsecondsSinceEpoch}-${_operationSequence++}';

Future<void> cancelAccountToolQuietly(
  NintendoAccountToolsBackend backend,
  String operationId,
) async {
  try {
    await backend.cancelAccountToolOperation(operationId);
  } catch (_) {
    // A retired consumer also ignores any result that arrives afterwards.
  }
}

/// Invalidates work across asynchronous credential reads and account removal.
/// Network cancellation itself remains in Rust.
class AccountToolRequests {
  final _active = <String, AccountToolRequest>{};

  AccountToolRequest begin(String accountId, String operationId) {
    final request = AccountToolRequest._(accountId, operationId);
    _active[operationId] = request;
    return request;
  }

  bool isCurrent(AccountToolRequest request) =>
      identical(_active[request.operationId], request);

  void finish(AccountToolRequest request) {
    if (isCurrent(request)) _active.remove(request.operationId);
  }

  void cancel(String operationId) => _active.remove(operationId);

  List<String> removeAccount(String accountId) {
    final ids = _active.entries
        .where((entry) => entry.value.accountId == accountId)
        .map((entry) => entry.key)
        .toList();
    for (final id in ids) {
      _active.remove(id);
    }
    return ids;
  }
}

class AccountToolRequest {
  AccountToolRequest._(this.accountId, this.operationId);
  final String accountId;
  final String operationId;
}
