import 'dart:typed_data';

import '../rust/models.dart';

/// Optional capabilities; existing desktop/test backends stay source-compatible.
abstract interface class NintendoAccountToolsBackend {
  Future<NintendoFriendsSnapshot> loadNintendoFriends(
    String accountId,
    String operationId,
  );
  Future<Uint8List> loadNintendoFriendAvatar(
    String accountId,
    String friendId,
    String operationId,
  );
  Future<SplatNetWebSession> prepareSplatNetSession(
    String accountId,
    String operationId, {
    bool forceRefresh = false,
  });
  Future<SeedExportPayload> prepareSeedExport(
    String accountId,
    String operationId,
  );
  Future<void> cancelAccountToolOperation(String operationId);
}
