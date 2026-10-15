import '../../backend/nintendo_account_tools_backend.dart';

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
    // Page/lease invalidation still prevents a late result from being used.
  }
}
