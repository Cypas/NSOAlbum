import 'package:flutter/material.dart';

import '../../backend/device_sync/account_gate.dart' show DeviceSyncBusy;
import '../../backend/device_sync/service_contract.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/device_sync/driver.dart' as driver;
import '../../rust/device_sync/planner.dart' as plan;
import '../../rust/device_sync/read_model.dart' as read;
import '../../rust/device_sync/space_budget.dart' as budget;
import '../../rust/device_sync/work.dart';
import '../display_time.dart';
import 'capacity_format.dart';
import 'direction.dart';
import 'display.dart';
import 'mode_selector.dart';
import 'transfer_progress.dart';

class DeviceSyncSessionPanel extends StatefulWidget {
  const DeviceSyncSessionPanel({super.key, required this.session});
  final DeviceSyncSessionController session;

  @override
  State<DeviceSyncSessionPanel> createState() => _DeviceSyncSessionPanelState();
}

class _DeviceSyncSessionPanelState extends State<DeviceSyncSessionPanel> {
  bool _acting = false, _configured = false, _consentMade = false;
  bool _phoneToDesktop = false, _overwrite = false, _accounts = false;
  bool _approved = false, _previewInvalid = false;
  Object? _error;
  driver.State? _errorStage;
  List<plan.Conflict>? _conflicts;
  String? _conflictNext;
  DeviceSyncPreviewView? _conflictPreview;
  late _SessionPanelStructure _structure;

  @override
  void initState() {
    super.initState();
    _structure = _readStructure(widget.session);
    widget.session.addListener(_sessionChanged);
  }

  @override
  void didUpdateWidget(covariant DeviceSyncSessionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      oldWidget.session.removeListener(_sessionChanged);
      _structure = _readStructure(widget.session);
      widget.session.addListener(_sessionChanged);
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_sessionChanged);
    super.dispose();
  }

  void _sessionChanged() {
    final next = _readStructure(widget.session);
    if (!mounted || next == _structure) return;
    setState(() => _structure = next);
  }

  _SessionPanelStructure _readStructure(DeviceSyncSessionController session) {
    final view = session.snapshot?.value;
    final progress = session.presentationProgress ?? session.snapshot?.progress;
    final transferring = view?.stage == driver.State.transferring;
    return (
      pairing: view?.pairing,
      confirmationAvailable: view?.confirmationAvailable,
      invitation: session.invitation,
      confirmationCode: session.confirmationCode,
      peerName: view?.peerName,
      transport: view?.transport,
      host: view?.host,
      controller: view?.controller,
      phoneControlled: view?.phoneControlled,
      accountsConsentAuthorized: view?.accountsConsentAuthorized,
      previewApproved: view?.previewApproved,
      source: view?.source,
      configuration: view?.configuration,
      stage: view?.stage,
      terminal: view?.terminal,
      cleanupPending: view?.cleanupPending,
      localApplyInstalled: view?.localApplyInstalled,
      sourceGrantIssued: view?.sourceGrantIssued,
      transportDetached: view?.transportDetached,
      workStage: transferring ? null : progress?.workStage,
      workActive: transferring || progress?.workActive == true,
      busy: session.busy,
      closed: session.closed,
      confirmedLocally: session.confirmedLocally,
      accountsAuthorized: session.accountsAuthorized,
      proposedConfiguration: session.proposedConfiguration,
      preview: session.preview,
      issue: session.issue,
      transportIssue: session.transportIssue,
      readError: session.snapshot?.error,
      tcpError: session.snapshot?.tcp?.error,
      localCleanupPending: session.localCleanupPending,
    );
  }

  Future<void> _act(Future<void> Function() action) async {
    if (_acting || widget.session.busy || widget.session.closed) return;
    setState(() {
      _acting = true;
      _error = null;
    });
    try {
      await action();
      if (!widget.session.closed) await widget.session.refresh();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _errorStage = widget.session.snapshot?.value?.stage;
        });
      }
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _review() async {
    await widget.session.refreshPreview();
    if (!mounted) return;
    setState(() {
      _previewInvalid = false;
      _conflicts = null;
      _conflictNext = null;
      _conflictPreview = null;
    });
  }

  Future<void> _loadConflicts(DeviceSyncPreviewView shown) async {
    final page = await widget.session.conflicts(
      shown,
      cursor: identical(shown, _conflictPreview) ? _conflictNext : null,
    );
    if (page.error case final error?) throw DeviceSyncReadFailure(error);
    final value = page.value;
    if (value == null) {
      throw const DeviceSyncReadFailure(read.ReadError.unavailable);
    }
    if (mounted) {
      setState(() {
        // Bounded page replaces the old page rather than accumulating it.
        _conflicts = value.items;
        _conflictNext = value.next;
        _conflictPreview = shown;
      });
    }
  }

  Future<void> _approve(DeviceSyncPreviewView shown) async {
    if (shown.library.mode == plan.SyncMode.overwrite) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            context.l10n.select(
              zh: '覆盖接收端图库？',
              en: 'Overwrite the receiving library?',
            ),
          ),
          content: Text(
            context.l10n.select(
              zh: '接收端独有项目将从当前图库移出，并保留可恢复备份。源端不会更改。',
              en: 'Receiver-only items will be removed from its current library and kept in a recovery backup. The source will not change.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
            ),
            FilledButton(
              key: const Key('device-confirm-overwrite'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                context.l10n.select(zh: '确认覆盖', en: 'Confirm overwrite'),
              ),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    try {
      await widget.session.approvePreview(shown);
      if (mounted) setState(() => _approved = true);
    } catch (_) {
      if (mounted) setState(() => _previewInvalid = true);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final value = session.snapshot;
    final view = value?.value;
    final progress = session.presentationProgress ?? value?.progress;
    final transferring = view?.stage == driver.State.transferring;
    final workActive =
        (transferring || progress?.workActive == true) &&
        view?.terminal != true;
    final pinning =
        !transferring && workActive && progress?.workStage == WorkStage.pinning;
    final disabled = _acting || session.busy || session.closed || workActive;
    final currentPreview = session.preview;
    final controlling = view?.controller == true;
    final delegated = view?.phoneControlled == true;
    final mayReview = delegated ? controlling : view?.source == false;
    final localContinuation =
        view?.localApplyInstalled == true &&
        view?.source == false &&
        view?.transportDetached == true &&
        view?.terminal == false;
    final sourceWaiting =
        view?.source == true &&
        view?.sourceGrantIssued == true &&
        (view?.stage == driver.State.verifying ||
            view?.stage == driver.State.completedUnconfirmed);
    final transportCannotUndoOutcome =
        localContinuation ||
        sourceWaiting ||
        view?.stage == driver.State.completed;
    final tcpFailure = transportCannotUndoOutcome
        ? null
        : session.transportIssue ?? value?.tcp?.error;
    final reportedFailure = session.issue ?? value?.error ?? tcpFailure;
    final readFailure = workActive && reportedFailure == read.ReadError.busy
        ? null
        : reportedFailure;
    final supersededBusy =
        _error is DeviceSyncBusy &&
        view != null &&
        readFailure != read.ReadError.busy &&
        (workActive || view.stage != _errorStage || readFailure != null);
    final actionError = supersededBusy ? null : _error;
    final children = <Widget>[
      if (view != null) ...[
        DeviceSyncStatusLabel(
          stage: view.stage,
          pinning: pinning,
          reviewing: view.stage == driver.State.awaitingApproval && mayReview,
        ),
        if (view.peerName case final name?
            when !(view.stage == driver.State.awaitingApproval && mayReview))
          Text(context.l10n.select(zh: '对端设备：$name', en: 'Peer device: $name')),
        if (view.configuration case final config?)
          _configuration(
            config.phoneToDesktop,
            config.mode == plan.SyncMode.overwrite,
            config.includeAccounts,
          ),
        if (localContinuation)
          Semantics(
            key: const Key('device-local-continuation'),
            liveRegion: true,
            child: Text(
              context.l10n.select(
                zh: '连接已断开，正在本机完成同步。请保持应用运行。',
                en: 'Connection closed. Finishing sync on this device. Keep the app open.',
              ),
            ),
          ),
        if (sourceWaiting && !view.terminal)
          Semantics(
            liveRegion: true,
            child: Text(
              context.l10n.select(
                zh: '正在等待接收设备确认结果。断开连接后，请在接收设备查看。',
                en: 'Waiting for the receiving device to confirm the result. If disconnected, check the receiving device.',
              ),
            ),
          ),
        if (view.stage == driver.State.completed &&
            (view.cleanupPending || session.localCleanupPending))
          Semantics(
            key: const Key('device-local-cleanup'),
            liveRegion: true,
            child: Text(
              context.l10n.select(
                zh: '同步已完成，仍需完成清理。请保持应用运行。',
                en: 'Sync is complete. Cleanup is still pending. Keep the app open.',
              ),
            ),
          )
        else if (view.cleanupPending)
          Text(
            context.l10n.select(
              zh: '正在等待安全清理或补偿结束。请勿中断应用。',
              en: 'Waiting for safe cleanup or compensation. Keep the app open.',
            ),
          ),
      ],
      if (view?.terminal == false &&
          view?.pairing == read.PairingStage.awaitingConfirmation &&
          session.confirmationCode != null) ...[
        const SizedBox(height: 12),
        Text(
          context.l10n.select(
            zh: '请核对两端确认码',
            en: 'Compare the code on both devices',
          ),
        ),
        Text(
          session.confirmationCode!,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        if (!session.confirmedLocally && (!delegated || controlling))
          FilledButton(
            key: const Key('device-confirm-pair'),
            onPressed: disabled ? null : () => _act(session.confirmPairing),
            child: Text(
              context.l10n.select(zh: '确认两端相同', en: 'Confirm matching codes'),
            ),
          )
        else
          Text(
            context.l10n.select(
              zh: delegated ? '请在手机确认本次连接。' : '已在本机确认，等待对端。',
              en: delegated
                  ? 'Confirm this connection on the phone.'
                  : 'Confirmed here. Waiting for the peer.',
            ),
          ),
      ],
      if (view?.pairing == read.PairingStage.confirmed &&
          controlling &&
          view?.stage == driver.State.configuring &&
          session.confirmedLocally &&
          !workActive &&
          !_configured) ...[
        DeviceSyncModeSelector(
          phoneToDesktop: _phoneToDesktop,
          overwrite: _overwrite,
          includeAccounts: _accounts,
          enabled: !disabled,
          onDirectionChanged: (value) =>
              setState(() => _phoneToDesktop = value),
          onOverwriteChanged: (value) => setState(() => _overwrite = value),
          onAccountsChanged: (value) => setState(() => _accounts = value),
        ),
        FilledButton(
          key: const Key('device-configure'),
          onPressed: disabled
              ? null
              : () => _act(() async {
                  await session.configure(
                    phoneToDesktop: _phoneToDesktop,
                    overwrite: _overwrite,
                    includeAccounts: _accounts,
                  );
                  if (mounted) setState(() => _configured = true);
                }),
          child: Text(
            context.l10n.select(zh: '使用此配置', en: 'Use this configuration'),
          ),
        ),
      ],
      if (delegated &&
          !controlling &&
          !workActive &&
          view?.stage == driver.State.configuring)
        Text(
          context.l10n.select(
            zh: '请在手机选择同步方向、模式和内容。',
            en: 'Choose the direction, mode and content on the phone.',
          ),
        ),
      if (view?.pairing == read.PairingStage.confirmed &&
          (!delegated || controlling) &&
          session.confirmedLocally &&
          view?.stage == driver.State.awaitingAccountConsent) ...[
        if (session.proposedConfiguration case final proposed?)
          _configuration(
            proposed.phoneToDesktop,
            proposed.mode == plan.SyncMode.overwrite,
            proposed.includeAccounts,
          ),
        Text(
          context.l10n.select(
            zh: '此操作包含来源设备全部已保存账号及其登录凭据，凭据只保存在系统安全存储中。本次授权同时允许来源设备读取及接收设备保存账号；选择仅同步图库则不传输账号。',
            en: 'This includes every saved account and sign-in credential on the source device, kept only in protected system storage. Consent allows the source to read and the receiver to save accounts for this sync. Choose library only to exclude accounts.',
          ),
        ),
        if (!_consentMade && !session.accountsAuthorized) ...[
          FilledButton(
            key: const Key('device-allow-accounts'),
            onPressed: disabled
                ? null
                : () => _act(() async {
                    await session.consentAccounts(accepted: true);
                    if (mounted) setState(() => _consentMade = true);
                  }),
            child: Text(
              context.l10n.select(
                zh: '允许本次账号同步',
                en: 'Allow accounts for this sync',
              ),
            ),
          ),
          OutlinedButton(
            key: const Key('device-no-accounts'),
            onPressed: disabled
                ? null
                : () => _act(() async {
                    await session.consentAccounts(accepted: false);
                    if (mounted) setState(() => _consentMade = true);
                  }),
            child: Text(context.l10n.select(zh: '仅同步图库', en: 'Library only')),
          ),
        ] else
          Text(
            context.l10n.select(
              zh: '已记录本次授权，正在准备账号预览。',
              en: 'Consent recorded. Preparing the account preview.',
            ),
          ),
      ],
      if (view?.stage == driver.State.awaitingApproval &&
          mayReview &&
          !_approved) ...[
        if (currentPreview != null) ..._preview(currentPreview, disabled),
        if (currentPreview == null)
          OutlinedButton.icon(
            key: const Key('device-review-preview'),
            onPressed: disabled ? null : () => _act(_review),
            icon: const Icon(Icons.refresh),
            label: Text(
              context.l10n.select(zh: '重新加载预览', en: 'Reload preview'),
            ),
          ),
      ],
      if (view?.stage == driver.State.awaitingApproval && !mayReview)
        Text(
          context.l10n.select(
            zh: '接收设备会核对空间，请在手机查看并确认预览。',
            en: 'The receiving device will check available space. Review and confirm the preview on the phone.',
          ),
        ),
      if (view?.terminal != true)
        DeviceSyncTransferProgress(
          key: const Key('device-transfer-progress-section'),
          session: session,
        ),
      if (actionError != null || readFailure != null) ...[
        const SizedBox(height: 12),
        Text(
          deviceSyncError(
            context,
            actionError ?? DeviceSyncReadFailure(readFailure!),
          ),
          key: const Key('device-session-error'),
        ),
      ],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _configuration(bool phoneToDesktop, bool overwrite, bool accounts) {
    final mode = overwrite
        ? context.l10n.select(zh: '覆盖', en: 'Overwrite')
        : context.l10n.select(zh: '融合', en: 'Merge');
    final scope = accounts
        ? context.l10n.select(zh: '图库与账号', en: 'Library and accounts')
        : context.l10n.select(zh: '仅图库', en: 'Library only');
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        DeviceSyncDirectionLabel(phoneToDesktop: phoneToDesktop),
        Text('$mode · $scope'),
      ],
    );
  }

  List<Widget> _preview(DeviceSyncPreviewView shown, bool disabled) {
    final summary = shown.library;
    final conflicts = summary.conflicts;
    return [
      const Divider(),
      DeviceChangeCounts(
        title: context.l10n.select(zh: '媒体', en: 'Media'),
        counts: summary.media,
      ),
      DeviceChangeCounts(
        title: context.l10n.select(zh: '相册', en: 'Albums'),
        counts: summary.albums,
        icon: Icons.collections_bookmark_outlined,
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.swap_vert),
        title: Text(
          context.l10n.select(
            zh: '需传输 ${formatDeviceCapacity(summary.space.newStagingBytes)}',
            en: 'To transfer: ${formatDeviceCapacity(summary.space.newStagingBytes)}',
          ),
        ),
      ),
      if (summary.receiverBudget case final receiver?) ...[
        for (final volume in receiver.volumes)
          Text(
            context.l10n.select(
              zh: '${_storageRoles(volume.roles)}：预计所需 ${formatDeviceCapacity(volume.requiredBytes)} · 剩余 ${formatDeviceCapacity(volume.availableBytes)}。',
              en: '${_storageRoles(volume.roles)}: estimated required ${formatDeviceCapacity(volume.requiredBytes)} · available ${formatDeviceCapacity(volume.availableBytes)}.',
            ),
          ),
        Text(
          context.l10n.select(
            zh: '接收预算已包含元数据、文件分配估计与安全余量；实际可用空间仍可能变化。',
            en: 'The receiving budget includes metadata, allocation estimates and a safety margin. Available space can still change.',
          ),
        ),
      ],
      ExpansionTile(
        key: const Key('device-space-details'),
        leading: const Icon(Icons.storage_outlined),
        title: Text(context.l10n.select(zh: '空间明细', en: 'Storage details')),
        children: [
          Text(
            context.l10n.select(
              zh: '可复用 ${formatDeviceCapacity(summary.space.reusableOriginalBytes)} · 备份原件 ${formatDeviceCapacity(summary.space.backupOriginalBytes)} · 备份复制 ${formatDeviceCapacity(summary.space.backupBytesIfCopied)} · 内容总量 ${formatDeviceCapacity(summary.space.conservativeContentBytes)}',
              en: 'Reusable ${formatDeviceCapacity(summary.space.reusableOriginalBytes)} · backup originals ${formatDeviceCapacity(summary.space.backupOriginalBytes)} · backup copy ${formatDeviceCapacity(summary.space.backupBytesIfCopied)} · content total ${formatDeviceCapacity(summary.space.conservativeContentBytes)}',
            ),
          ),
          if (summary.space.excludesMetadataAndFilesystemOverhead)
            Text(
              context.l10n.select(
                zh: '原件统计不含元数据和文件系统开销，以接收预算为准。',
                en: 'Original sizes exclude metadata and filesystem overhead. Use the receiving budget.',
              ),
            ),
        ],
      ),
      if (conflicts.unknownRevision +
              conflicts.equalRevision +
              conflicts.clockSkew >
          BigInt.zero)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                context.l10n.select(
                  zh: '有部分项目的修改时间无法确定，请查看冲突。',
                  en: 'Some modification times are uncertain. Review the conflicts.',
                ),
              ),
            ),
          ],
        ),
      if (summary.mode == plan.SyncMode.overwrite)
        Text(
          context.l10n.select(
            zh: '覆盖会从当前图库移出目标独有项目，并保留可恢复备份；不会自动清理备份。',
            en: 'Overwrite removes receiver-only items from the current library and retains a recoverable backup. Backups are not automatically deleted.',
          ),
        ),
      if (shown.accounts case final accounts?)
        DeviceAccountChanges(counts: accounts)
      else
        Text(
          context.l10n.select(zh: '账号保持不变。', en: 'Accounts remain unchanged.'),
        ),
      if (conflicts.unknownRevision +
              conflicts.equalRevision +
              conflicts.clockSkew >
          BigInt.zero)
        OutlinedButton(
          key: const Key('device-conflicts'),
          onPressed: disabled ? null : () => _act(() => _loadConflicts(shown)),
          child: Text(
            context.l10n.select(
              zh: _conflicts == null
                  ? '查看冲突'
                  : _conflictNext != null
                  ? '下一页冲突'
                  : '重新查看冲突',
              en: _conflicts == null
                  ? 'Review conflicts'
                  : _conflictNext != null
                  ? 'Next conflict page'
                  : 'Review conflicts again',
            ),
          ),
        ),
      if (identical(shown, _conflictPreview))
        for (final item in _conflicts ?? <plan.Conflict>[])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_conflictText(item)),
          ),
      FilledButton(
        key: const Key('device-approve-preview'),
        onPressed: disabled || _previewInvalid
            ? null
            : () => _act(() => _approve(shown)),
        child: Text(
          context.l10n.select(
            zh: '确认同步并在接收端应用',
            en: 'Confirm sync and apply on the receiver',
          ),
        ),
      ),
    ];
  }

  String _storageRoles(List<budget.StorageRole> roles) => roles
      .map(
        (role) => switch (role) {
          budget.StorageRole.staging => context.l10n.select(
            zh: '暂存',
            en: 'Staging',
          ),
          budget.StorageRole.originals => context.l10n.select(
            zh: '图库',
            en: 'Library',
          ),
          budget.StorageRole.database => context.l10n.select(
            zh: '数据库',
            en: 'Database',
          ),
        },
      )
      .join(' / ');

  String _conflictText(plan.Conflict item) {
    final reason = switch (item.reason) {
      plan.ConflictReason.unknownRevision => context.l10n.select(
        zh: '未知时间',
        en: 'Unknown time',
      ),
      plan.ConflictReason.equalRevision => context.l10n.select(
        zh: '同时间内容冲突',
        en: 'Equal-time conflict',
      ),
      plan.ConflictReason.clockSkew => context.l10n.select(
        zh: '设备时钟偏差',
        en: 'Device clock skew',
      ),
    };
    final source = item.sourceRevision == null
        ? context.l10n.select(zh: '未知', en: 'Unknown')
        : formatUserDateTime(item.sourceRevision!);
    final target = item.targetRevision == null
        ? context.l10n.select(zh: '未知', en: 'Unknown')
        : formatUserDateTime(item.targetRevision!);
    // Native identities are bounded logical object identifiers, never paths.
    return context.l10n.select(
      zh: '$reason · ${item.identity}\n来源：$source\n本机：$target\n采用源端内容',
      en: '$reason · ${item.identity}\nSource: $source\nThis device: $target\nSource content will be used',
    );
  }
}

typedef _SessionPanelStructure = ({
  read.PairingStage? pairing,
  bool? confirmationAvailable,
  String? invitation,
  String? confirmationCode,
  String? peerName,
  read.TransportKind? transport,
  bool? host,
  bool? controller,
  bool? phoneControlled,
  bool? accountsConsentAuthorized,
  bool? previewApproved,
  bool? source,
  read.AgreedConfiguration? configuration,
  driver.State? stage,
  bool? terminal,
  bool? cleanupPending,
  bool? localApplyInstalled,
  bool? sourceGrantIssued,
  bool? transportDetached,
  WorkStage? workStage,
  bool workActive,
  bool busy,
  bool closed,
  bool confirmedLocally,
  bool accountsAuthorized,
  DeviceSyncProposal? proposedConfiguration,
  DeviceSyncPreviewView? preview,
  read.ReadError? issue,
  read.ReadError? transportIssue,
  read.ReadError? readError,
  read.ReadError? tcpError,
  bool localCleanupPending,
});
