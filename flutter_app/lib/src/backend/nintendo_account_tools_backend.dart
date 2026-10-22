import 'dart:typed_data';

import '../rust/models.dart';

abstract interface class NintendoGameImageBackend {
  Future<Uint8List> loadNintendoGameImage(
    String accountId,
    String gameName,
    String operationId,
  );
}

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

  Future<List<NintendoFriendGame>> loadNintendoFriendPlayLog(
    String accountId,
    String friendId,
    String operationId,
  );
  Future<NintendoFriendCodeSnapshot> loadNintendoFriendCode(
    String accountId,
    String operationId,
  );
  Future<NintendoFriendCodeUser> lookupNintendoFriendCode(
    String accountId,
    String friendCode,
    String operationId,
  );
  Future<NintendoFriendRequestResult> sendNintendoFriendRequest(
    String accountId,
    String friendId,
    String operationId,
  );
  Future<void> updateNintendoFriendNote(
    String accountId,
    String friendId,
    String note,
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
