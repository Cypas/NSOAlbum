import 'dart:async';

import 'package:flutter/foundation.dart';

import '../backend/app_backend.dart';
import '../rust/models.dart';
import '../rust/settings.dart';
import 'settings_controller.dart';
import 'settings_copy.dart';
import 'sync_controller.dart';

Future<void> completeNintendoAccountLogin({
  required AppBackend backend,
  required SettingsController settings,
  required String callback,
}) async {
  await backend.completeNintendoLogin(callback);
  final policy = settings.value.syncPolicy;
  if (!policy.enabled) {
    await settings.save(
      copyAppSettings(
        settings.value,
        syncPolicy: SyncPolicy(
          enabled: true,
          activeIntervalMinutes: policy.activeIntervalMinutes,
          sleepAfterHours: policy.sleepAfterHours,
        ),
      ),
    );
  }
}

class TransferController extends ChangeNotifier {
  TransferController(
    this.backend,
    this.settings,
    this.sync, {
    this.onAccountChanged,
    this.onImported,
  });

  final AppBackend backend;
  final SettingsController settings;
  final SyncController sync;
  final Future<void> Function()? onAccountChanged;
  final VoidCallback? onImported;
  List<NintendoAccountProfile> accounts = [];
  Map<String, SyncRuntimeState> histories = {};
  String? selectedAccountId;
  List<GameTagSummary> games = [];
  List<String> paths = [];
  String gameName = '';
  ImportSummary? importSummary;
  OperationProgressValue? importProgress;
  Object? error;
  bool busy = false;
  bool loginStarted = false;
  bool loginInProgress = false;
  bool disposed = false;
  StreamSubscription<OperationProgressValue>? _importProgressSubscription;

  void publish() {
    if (!disposed) notifyListeners();
  }

  Future<void> refresh() async {
    try {
      final nextAccounts = await backend.listNintendoAccounts();
      final nextSelected = await backend.selectedNintendoAccountId;
      final nextGames = await backend.listGameTags();
      final nextHistories = <String, SyncRuntimeState>{};
      if (backend case final SyncHistoryBackend historyBackend) {
        for (final profile in nextAccounts) {
          nextHistories[profile.accountId] = await historyBackend
              .loadSyncAccountHistory(profile.accountId);
        }
      }
      if (disposed) return;
      accounts = nextAccounts;
      selectedAccountId = nextSelected;
      games = nextGames;
      histories = nextHistories;
      error = null;
    } catch (exception) {
      if (!disposed) error = exception;
    }
    publish();
  }

  Future<bool> perform(Future<void> Function() operation) async {
    if (busy || disposed) return false;
    busy = true;
    error = null;
    publish();
    try {
      await operation();
      return true;
    } catch (exception) {
      if (!disposed) error = exception;
      return false;
    } finally {
      busy = false;
      publish();
    }
  }

  Future<bool> selectAccount(String id) => perform(() async {
    await backend.selectNintendoAccount(id);
    await refresh();
    await onAccountChanged?.call();
  });

  Future<bool> removeAccount(String id) => perform(() async {
    await backend.removeNintendoAccount(id);
    await refresh();
    await onAccountChanged?.call();
  });

  Future<bool> beginLogin() => perform(() async {
    await backend.beginNintendoLogin();
    loginStarted = true;
  });

  Future<bool> completeLogin(String callback) =>
      perform(() async {
        if (!loginStarted) {
          throw StateError('pending sign-in page has not been opened');
        }
        loginInProgress = true;
        publish();
        final previousIds = (await backend.listNintendoAccounts())
            .map((account) => account.accountId)
            .toSet();
        await completeNintendoAccountLogin(
          backend: backend,
          settings: settings,
          callback: callback,
        );
        await refresh();
        await onAccountChanged?.call();
        final newIds = accounts
            .map((account) => account.accountId)
            .where((id) => !previousIds.contains(id))
            .toList();
        final authenticatedAccountId = newIds.firstOrNull ?? selectedAccountId;
        loginStarted = false;
        if (!disposed && authenticatedAccountId != null) {
          unawaited(sync.enqueueAuthenticatedAccount(authenticatedAccountId));
        }
      }).whenComplete(() {
        loginInProgress = false;
        publish();
      });

  void addPaths(Iterable<String> selected) {
    if (busy || disposed) return;
    paths = {...paths, ...selected}.toList();
    importSummary = null;
    importProgress = null;
    publish();
  }

  void removePath(String path) {
    if (busy || disposed) return;
    paths = paths.where((item) => item != path).toList();
    importSummary = null;
    importProgress = null;
    publish();
  }

  Future<bool> importSelected() => perform(() async {
    if (paths.isEmpty || gameName.trim().isEmpty) {
      throw StateError('Select media and a game tag before importing.');
    }
    importProgress = const OperationProgressValue(
      operationId: '',
      kind: 'custom_import',
      phase: 'discovering',
    );
    String? operationId;
    if (backend case final OperationProgressBackend progressBackend) {
      await _importProgressSubscription?.cancel();
      _importProgressSubscription = progressBackend.operationProgress.listen((
        value,
      ) {
        if (value.kind != 'custom_import') return;
        operationId ??= value.operationId;
        if (operationId != value.operationId) return;
        importProgress = value;
        publish();
      });
    }
    try {
      importSummary = await backend.importCustomFiles(
        List.of(paths),
        gameName.trim(),
      );
      onImported?.call();
      await refresh();
    } finally {
      await _importProgressSubscription?.cancel();
      _importProgressSubscription = null;
    }
  });

  @override
  void dispose() {
    disposed = true;
    unawaited(_importProgressSubscription?.cancel());
    _importProgressSubscription = null;
    super.dispose();
  }
}
