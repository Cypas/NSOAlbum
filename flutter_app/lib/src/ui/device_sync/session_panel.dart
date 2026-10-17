import 'package:flutter/material.dart';

import '../../backend/device_sync/account_gate.dart' show DeviceSyncBusy;
import '../../backend/device_sync/service_contract.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/device_sync/driver.dart' as driver;
import '../../rust/device_sync/planner.dart' as plan;
import '../../rust/device_sync/read_model.dart' as read;
import '../../rust/device_sync/runtime.dart' as runtime;
import '../../rust/device_sync/space_budget.dart' as budget;
import '../display_time.dart';
import 'capacity_format.dart';
import 'display.dart';
import 'mode_selector.dart';

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
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.session,
    builder: (context, _) {
      final session = widget.session;
      final value = session.snapshot;
      final view = value?.value;
      final disabled = _acting || session.busy || session.closed;
      final currentPreview = session.preview;
      final controlling = view?.controller == true;
      final delegated = view?.phoneControlled == true;
      final mayReview = delegated ? controlling : view?.source == false;
      final tcpFailure =
          view?.stage == driver.State.completed &&
              value?.tcp?.phase == runtime.TcpPhase.closed &&
              value?.tcp?.error == read.ReadError.disconnected
          ? null
          : value?.tcp?.error;
      final readFailure = session.issue ?? value?.error ?? tcpFailure;
      final supersededBusy =
          _error is DeviceSyncBusy &&
          view != null &&
          readFailure != read.ReadError.busy &&
          (view.stage != _errorStage || readFailure != null);
      final actionError = supersededBusy ? null : _error;
      final children = <Widget>[
        if (view != null) ...[
          Text(
            deviceSyncStage(context, view.stage),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (view.peerName case final name?)
            Text(
              context.l10n.select(zh: '对端设备：$name', en: 'Peer device: $name'),
            ),
          if (view.configuration case final config?)
            Text(
              _configuration(
                config.phoneToDesktop,
                config.mode == plan.SyncMode.overwrite,
                config.includeAccounts,
              ),
            ),
          if (view.cleanupPending)
            Text(
              context.l10n.select(
                zh: '正在等待安全清理或补偿结束。请勿中断应用。',
                en: 'Waiting for safe cleanup or compensation. Keep the app open.',
              ),
            ),
        ],
        if (view?.terminal == false &&
            (view?.pairing == read.PairingStage.awaitingConfirmation ||
                view?.pairing == read.PairingStage.confirmed) &&
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
            Text(
              _configuration(
                proposed.phoneToDesktop,
                proposed.mode == plan.SyncMode.overwrite,
                proposed.includeAccounts,
              ),
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
          OutlinedButton(
            key: const Key('device-review-preview'),
            onPressed: disabled ? null : () => _act(_review),
            child: Text(
              context.l10n.select(
                zh: '刷新并查看预览',
                en: 'Refresh and review changes',
              ),
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
        if (value != null && view?.terminal != true)
          ..._progress(value.progress, view?.stage),
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
    },
  );

  String _configuration(bool phoneToDesktop, bool overwrite, bool accounts) {
    final direction = phoneToDesktop
        ? context.l10n.select(zh: '手机 → 桌面', en: 'Phone → Desktop')
        : context.l10n.select(zh: '桌面 → 手机', en: 'Desktop → Phone');
    final mode = overwrite
        ? context.l10n.select(zh: '覆盖', en: 'Overwrite')
        : context.l10n.select(zh: '融合', en: 'Merge');
    final scope = accounts
        ? context.l10n.select(zh: '图库与账号', en: 'Library and accounts')
        : context.l10n.select(zh: '仅图库', en: 'Library only');
    return '$direction · $mode · $scope';
  }

  List<Widget> _preview(DeviceSyncPreviewView shown, bool disabled) {
    final summary = shown.library;
    final conflicts = summary.conflicts;
    return [
      const Divider(),
      if (summary.sourceDevice?.displayName case final name?)
        Text(context.l10n.select(zh: '来源设备：$name', en: 'Source device: $name')),
      DeviceChangeCounts(
        title: context.l10n.select(zh: '媒体', en: 'Media'),
        counts: summary.media,
      ),
      DeviceChangeCounts(
        title: context.l10n.select(zh: '相册', en: 'Albums'),
        counts: summary.albums,
      ),
      Text(
        context.l10n.select(
          zh: '原件内容估计：新传输 ${formatDeviceCapacity(summary.space.newStagingBytes)} · 可复用 ${formatDeviceCapacity(summary.space.reusableOriginalBytes)} · 备份原件 ${formatDeviceCapacity(summary.space.backupOriginalBytes)} · 备份需复制时 ${formatDeviceCapacity(summary.space.backupBytesIfCopied)} · 内容总量 ${formatDeviceCapacity(summary.space.conservativeContentBytes)}。',
          en: 'Original content estimate: new transfer ${formatDeviceCapacity(summary.space.newStagingBytes)} · reusable ${formatDeviceCapacity(summary.space.reusableOriginalBytes)} · backup originals ${formatDeviceCapacity(summary.space.backupOriginalBytes)} · backup if copied ${formatDeviceCapacity(summary.space.backupBytesIfCopied)} · content total ${formatDeviceCapacity(summary.space.conservativeContentBytes)}.',
        ),
      ),
      if (summary.space.excludesMetadataAndFilesystemOverhead)
        Text(
          context.l10n.select(
            zh: '此估计不包含元数据和文件系统额外占用。',
            en: 'Metadata and filesystem overhead are not included.',
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
      Text(
        context.l10n.select(
          zh: '源端优先：未知时间 ${conflicts.unknownRevision} · 同时间内容冲突 ${conflicts.equalRevision} · 时钟偏差 ${conflicts.clockSkew}。同步不会修改源端。',
          en: 'Source wins: unknown time ${conflicts.unknownRevision} · equal-time conflicts ${conflicts.equalRevision} · clock skew ${conflicts.clockSkew}. The source is unchanged.',
        ),
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

  List<Widget> _progress(read.ProgressView progress, driver.State? stage) {
    double? ratio(BigInt value, BigInt? total) =>
        total != null && total > BigInt.zero
        ? (value.toDouble() / total.toDouble()).clamp(0.0, .999)
        : null;
    return [
      if (progress.workActive) ...[
        const SizedBox(height: 12),
        LinearProgressIndicator(
          key: const Key('device-item-progress'),
          value: ratio(progress.scannedItems, progress.totalItems),
        ),
        Text(
          context.l10n.select(
            zh: '已处理项目 ${progress.scannedItems} / ${progress.totalItems ?? '…'}',
            en: 'Items processed ${progress.scannedItems} / ${progress.totalItems ?? '…'}',
          ),
        ),
      ],
      if (stage == driver.State.transferring &&
          progress.transferredBytes != null) ...[
        const SizedBox(height: 12),
        LinearProgressIndicator(
          key: const Key('device-byte-progress'),
          value: ratio(progress.transferredBytes!, progress.transferTotalBytes),
        ),
        Text(
          context.l10n.select(
            zh: '已传输 ${formatDeviceCapacity(progress.transferredBytes)} / ${formatDeviceCapacity(progress.transferTotalBytes, unknown: '未知')}',
            en: 'Transferred ${formatDeviceCapacity(progress.transferredBytes)} / ${formatDeviceCapacity(progress.transferTotalBytes, unknown: 'Unknown')}',
          ),
        ),
        Text(
          context.l10n.select(
            zh: '当前速度：${formatDeviceTransferRate(progress.transferBytesPerSecond, unknown: '未知')}',
            en: 'Current speed: ${formatDeviceTransferRate(progress.transferBytesPerSecond, unknown: 'Unknown')}',
          ),
          key: const Key('device-transfer-rate'),
        ),
      ],
    ];
  }
}
