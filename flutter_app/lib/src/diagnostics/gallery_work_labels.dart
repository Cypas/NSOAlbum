// Shared fixed labels only: this file is also consumed by the host Dart tool.
const secureReadCallerNames = {
  'RustBackend._readStoredAccountTokens',
  'RustBackend._readAccountTokens',
  'RustBackend._readCachedProfiles',
  'RustBackend._readRawProfiles',
  'RustBackend._isSignedIn',
  'RustBackend._nintendoAccountProfile',
  'RustBackend._listNintendoAccounts',
  'RustBackend._selectedNintendoAccountId',
  'RustBackend.listNintendoAccountNameHistory',
  'RustBackend.cachedNintendoAccountProfile',
  'RustBackend.loadNintendoFriendCode',
  'readRawAccountKeys',
  'FlutterAccountSecureStorage.read',
  'AutomaticSyncCoordinator._reschedule',
  'AutomaticSyncCoordinator._applySettingsChange',
  'AutomaticSyncCoordinator._accountGateChanged',
  'AutomaticSyncCoordinator._syncChanged',
  'AutomaticSyncCoordinator.accountChanged',
  'AutomaticSyncCoordinator.start',
  'SyncController._runAccountQueue',
  'SyncController.refreshAccountScheduleStatuses',
  'SyncController.dueAccountIds',
  '_HomeShellState._readAccountSnapshot',
  '_HomeShellState._reloadAccountSnapshot',
  'TransferController.load',
  'TransferController.refresh',
};

const secureReadKeyGroups = {
  'tokens',
  'profiles',
  'selection',
  'legacy',
  'friendCode',
  'other',
};

List<String> secureReadCallers(StackTrace stack) {
  final result = <String>[];
  final frame = RegExp(
    r'^#\d+\s+([a-zA-Z0-9_$.]+)(?:\.<anonymous closure>)?\s+\(',
  );
  for (final line in stack.toString().split('\n')) {
    final name = frame.firstMatch(line.trimLeft())?.group(1);
    if (name != null &&
        secureReadCallerNames.contains(name) &&
        !result.contains(name)) {
      result.add(name);
      if (result.length == 12) break;
    }
  }
  return result;
}

String secureReadKeyGroup(String key) => switch (key) {
  'nintendo.account_tokens.v1' => 'tokens',
  'nintendo.account_profiles.v1' => 'profiles',
  'nintendo.selected_account.v1' => 'selection',
  'nintendo.session_token' => 'legacy',
  _ => key.startsWith('nintendo.friend_code.v1.') ? 'friendCode' : 'other',
};
