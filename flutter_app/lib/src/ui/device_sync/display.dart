import 'package:flutter/material.dart';

import '../../backend/device_sync/account_coordinator.dart'
    show AccountPreviewChanged, AccountRecoveryRequired;
import '../../backend/device_sync/account_gate.dart' show DeviceSyncBusy;
import '../../backend/device_sync/account_storage.dart'
    show AccountConsentRequired, AccountPayloadInvalid;
import '../../backend/device_sync/service_contract.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/device_sync/driver.dart' as driver;
import '../../rust/device_sync/read_model.dart' as read;
import '../../rust/device_sync/runtime.dart' show DeviceCommandError;
import '../../rust/device_sync/work.dart' show PreparationStage;
import 'capacity_format.dart';

String deviceSyncError(BuildContext context, Object error) {
  final code = switch (error) {
    DeviceSyncReadFailure(:final code) => code,
    DeviceCommandError(:final code) => code,
    AccountPreviewChanged() => read.ReadError.previewChanged,
    AccountRecoveryRequired() => read.ReadError.recoveryRequired,
    DeviceSyncBusy() => read.ReadError.busy,
    _ => null,
  };
  final (zh, en) = switch (code) {
    read.ReadError.previewChanged => (
      '预览已变化或过期。请刷新预览并重新确认；若连接已结束，请重新扫码。',
      'The preview changed or expired. Refresh and confirm again, or scan a new code if the connection ended.',
    ),
    read.ReadError.recoveryRequired => (
      '需要完成数据恢复检查。请返回并完成恢复后重试。',
      'A data recovery check is required. Return and complete recovery before retrying.',
    ),
    read.ReadError.busy => (
      '正在等待当前操作安全结束，请稍后重试。',
      'Waiting for the current operation to finish safely. Retry shortly.',
    ),
    read.ReadError.permissionDenied => (
      '未获授权。请检查相机或所选目录的访问权限后重试。',
      'Access was not granted. Check camera or selected-folder access and retry.',
    ),
    read.ReadError.unavailable => (
      '此连接方式当前不可用。USB 需要随应用提供的设备组件和可用存储；请检查连接后重试。',
      'This connection is unavailable. USB needs the bundled device component and accessible storage. Check the connection and retry.',
    ),
    read.ReadError.insufficientSpace => (
      '接收设备空间不足，请释放空间后重新连接。',
      'The receiving device does not have enough space. Free up space and reconnect.',
    ),
    read.ReadError.timeout => (
      '连接超时。USB 文件传输请解锁手机、确认已选择文件传输并保持页面在前台；Wi-Fi 请检查同一局域网、网络隔离或防火墙，然后重试。',
      'The connection timed out. For USB file transfer, unlock the phone, confirm file transfer is selected and keep this page in front. For Wi-Fi, check the local network, network isolation or firewall, then retry.',
    ),
    read.ReadError.disconnected => (
      '连接已断开。请检查同一局域网、网络隔离、防火墙或 USB 连接，然后重新扫码。',
      'The connection was lost. Check the same local network, network isolation, firewall, or USB connection, then scan a new code.',
    ),
    read.ReadError.applyFailed => (
      '图库应用阶段未完成。已校验的暂存文件会保留。重新配对后会核对清单、目标图库和暂存文件信息；匹配的缓存可复用而不重传，缺失或不匹配的文件需要重新传输。',
      'Applying the library did not complete. Verified staged files are retained. After re-pairing, the manifest, target library and staged file information are checked; matching cached files can be reused without retransferring, while missing or mismatched files must be sent again.',
    ),
    read.ReadError.cancelled => ('操作已取消。', 'Operation cancelled.'),
    read.ReadError.invalidInput => (
      '传输数据或交换目录校验未通过，可能是传输中断或目录数据损坏。若包含账号，请确认两端均支持账号名称历史；也可重新连接并选择仅同步图库。已校验的暂存文件会保留。',
      'Transfer data or the exchange folder failed validation, possibly due to interruption or corrupt data. For account sync, check that both devices support account name history, or reconnect with library-only sync. Verified staged files are retained.',
    ),
    read.ReadError.versionMismatch => (
      '两端软件版本、构建号或传输协议不兼容。请更新两端应用至相同版本和构建，再重新生成二维码。',
      'The app version, build number or transfer protocol is incompatible. Update both devices to matching versions and builds, then generate a new code.',
    ),
    _ when error is DeviceInvitationFailure => (
      '二维码信息无效。请在电脑上生成新的二维码。',
      'The QR code is invalid. Generate a new code on the computer.',
    ),
    _ when error is AccountConsentRequired => (
      '读取账号变化前需要单独授权。',
      'Separate consent is required before reading account changes.',
    ),
    _ when error is AccountPayloadInvalid => (
      '账号或名称历史无法安全同步：数据无效或超出容量限制。未应用账号更改；可取消账号同步后仅同步图库。',
      'Accounts or name history could not be synced safely: the data is invalid or exceeds capacity. No account changes were applied. Cancel account sync to transfer only the library.',
    ),
    _ when error is DeviceBackupUnavailable => (
      '此备份不具备恢复条件。它可能不完整、缺少账号材料或仅用于内部恢复。',
      'This backup cannot be restored. It may be incomplete, lack account materials, or be reserved for internal recovery.',
    ),
    _ => (
      '操作未完成，数据仍受保护。请检查连接和存储后重试。',
      'The operation did not complete. Your data remains protected. Check the connection and storage before retrying.',
    ),
  };
  // Never render exception.toString(): it can contain protocol or OS secrets.
  return context.l10n.select(zh: zh, en: en);
}

String deviceSyncStage(BuildContext context, driver.State stage) {
  final (zh, en) = switch (stage) {
    driver.State.pairing => (
      '等待设备连接与确认',
      'Waiting for connection and confirmation',
    ),
    driver.State.configuring => (
      '等待手机选择同步内容',
      'Waiting for phone configuration',
    ),
    driver.State.scanning => ('正在扫描图库', 'Scanning library'),
    driver.State.comparing => ('正在比较图库', 'Comparing libraries'),
    driver.State.awaitingApproval => (
      '等待手机确认预览',
      'Waiting for preview confirmation on the phone',
    ),
    driver.State.awaitingAccountConsent => (
      '等待手机授权账号同步',
      'Waiting for account consent on the phone',
    ),
    driver.State.awaitingAccountFinal ||
    driver.State.awaitingTargetAccountFinal => (
      '正在准备账号提交',
      'Preparing account commit',
    ),
    driver.State.awaitingExternal => ('正在安全保存账号', 'Saving accounts safely'),
    driver.State.transferring => ('正在传输', 'Transferring'),
    driver.State.verifying => ('正在校验', 'Verifying'),
    driver.State.applying => ('正在应用更改', 'Applying changes'),
    driver.State.completed => ('同步完成', 'Sync complete'),
    driver.State.completedUnconfirmed => (
      '结果未确认，请在接收设备查看。',
      'Result unconfirmed. Check the receiving device.',
    ),
    driver.State.cancelled => ('同步已取消', 'Sync cancelled'),
    driver.State.failed => ('同步未完成', 'Sync did not complete'),
    driver.State.recoveryPending => ('需要恢复数据', 'Recovery required'),
  };
  return context.l10n.select(zh: zh, en: en);
}

String deviceSyncResult(
  BuildContext context, {
  required driver.State stage,
  required read.ReadError? error,
  required BigInt? transferredBytes,
  BigInt? processedItems,
  BigInt? totalItems,
  BigInt? processedBytes,
  BigInt? totalBytes,
}) {
  final reason =
      stage == driver.State.cancelled || error == read.ReadError.cancelled
      ? context.l10n.select(zh: '同步已取消', en: 'Sync cancelled')
      : switch (error) {
          read.ReadError.disconnected => context.l10n.select(
            zh: '连接已断开',
            en: 'Connection was lost',
          ),
          read.ReadError.timeout => context.l10n.select(
            zh: '连接超时',
            en: 'Connection timed out',
          ),
          read.ReadError.applyFailed => context.l10n.select(
            zh: '应用阶段未完成；重新配对并核对文件信息后可复用匹配缓存',
            en: 'Apply did not complete; matching cache can be reused after re-pairing and checking file information',
          ),
          read.ReadError.unavailable => context.l10n.select(
            zh: '同步服务不可用',
            en: 'Sync service unavailable',
          ),
          read.ReadError.insufficientSpace => context.l10n.select(
            zh: '接收设备空间不足',
            en: 'The receiving device ran out of space',
          ),
          _ => deviceSyncStage(context, stage),
        };
  final transferred = transferredBytes == null
      ? null
      : context.l10n.select(
          zh: '已传输 ${formatDeviceCapacity(transferredBytes)}',
          en: 'Transferred ${formatDeviceCapacity(transferredBytes)}',
        );
  final items = processedItems == null
      ? null
      : context.l10n.select(
          zh: '已处理项目 $processedItems / ${totalItems ?? '…'}',
          en: 'Items processed $processedItems / ${totalItems ?? '…'}',
        );
  final bytes = processedBytes == null
      ? null
      : context.l10n.select(
          zh: '已校验 ${formatDeviceCapacity(processedBytes)} / ${formatDeviceCapacity(totalBytes)}',
          en: 'Verified ${formatDeviceCapacity(processedBytes)} / ${formatDeviceCapacity(totalBytes)}',
        );
  return [reason, ?items, ?bytes, ?transferred].join(' · ');
}

bool deviceSyncStageShowsProgress(driver.State stage) => switch (stage) {
  driver.State.scanning ||
  driver.State.comparing ||
  driver.State.verifying ||
  driver.State.applying => true,
  _ => false,
};

String deviceSyncStageProgressLabel(BuildContext context, driver.State stage) {
  final stageLabel = deviceSyncStage(context, stage);
  return context.l10n.select(
    zh: '$stageLabel，正在处理',
    en: '$stageLabel, in progress',
  );
}

PreparationStage? deviceSyncActivePreparation(
  driver.State stage,
  read.ProgressView? progress,
) => switch (stage) {
  driver.State.scanning || driver.State.comparing => progress?.preparationPhase,
  driver.State.configuring when progress?.workActive == true =>
    progress?.preparationPhase,
  _ => null,
};

String deviceSyncPreparationStage(
  BuildContext context,
  PreparationStage phase,
) {
  final (zh, en) = switch (phase) {
    PreparationStage.readingLibrary => ('正在读取图库', 'Reading library'),
    PreparationStage.comparingRecords => ('正在比较记录', 'Comparing records'),
    PreparationStage.checkingCache => ('正在检查已传输文件', 'Checking staged files'),
    PreparationStage.checkingSpace => ('正在检查可用空间', 'Checking available space'),
    PreparationStage.preparingPreview => (
      '正在准备同步确认',
      'Preparing sync confirmation',
    ),
    PreparationStage.waitingForPeer => (
      '正在等待对端核对',
      'Waiting for peer verification',
    ),
  };
  return context.l10n.select(zh: zh, en: en);
}

/// The indicator is decorative; the full localized status is announced once.
class DeviceSyncStatusLabel extends StatelessWidget {
  const DeviceSyncStatusLabel({
    super.key,
    required this.stage,
    this.pinning = false,
    this.reviewing = false,
    this.preparationPhase,
  });

  final driver.State stage;
  final bool pinning, reviewing;
  final PreparationStage? preparationPhase;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final text = preparationPhase != null
        ? deviceSyncPreparationStage(context, preparationPhase!)
        : pinning
        ? context.l10n.select(zh: '正在校验图库原件', en: 'Verifying library originals')
        : reviewing
        ? context.l10n.select(zh: '预览变更内容', en: 'Preview changes')
        : deviceSyncStage(context, stage);
    final color = switch (stage) {
      _ when pinning => dark ? Colors.blue.shade400 : Colors.blue.shade700,
      driver.State.completed =>
        dark ? Colors.green.shade400 : Colors.green.shade700,
      driver.State.completedUnconfirmed =>
        dark ? Colors.amber.shade400 : Colors.amber.shade800,
      driver.State.failed || driver.State.recoveryPending =>
        dark ? Colors.red.shade400 : Colors.red.shade700,
      driver.State.pairing ||
      driver.State.configuring ||
      driver.State.awaitingApproval ||
      driver.State.awaitingAccountConsent ||
      driver.State.cancelled =>
        dark ? Colors.grey.shade400 : Colors.grey.shade600,
      driver.State.scanning ||
      driver.State.comparing ||
      driver.State.awaitingAccountFinal ||
      driver.State.awaitingTargetAccountFinal ||
      driver.State.awaitingExternal ||
      driver.State.transferring ||
      driver.State.verifying ||
      driver.State.applying =>
        dark ? Colors.blue.shade400 : Colors.blue.shade700,
    };
    return Semantics(
      key: const Key('device-sync-status'),
      label: text,
      liveRegion: true,
      child: ExcludeSemantics(
        child: Row(
          children: [
            Container(
              key: const Key('device-sync-status-dot'),
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text, style: Theme.of(context).textTheme.titleMedium),
            ),
          ],
        ),
      ),
    );
  }
}

class DeviceChangeCounts extends StatelessWidget {
  const DeviceChangeCounts({
    super.key,
    required this.title,
    required this.counts,
    this.icon = Icons.photo_library_outlined,
  });
  final String title;
  final read.ChangeCounts counts;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            context.l10n.select(
              zh: '$title：新增 ${counts.added} · 替换 ${counts.replaced} · 移出 ${counts.removed} · 保留 ${counts.kept}',
              en: '$title: Added ${counts.added} · Replaced ${counts.replaced} · Removed ${counts.removed} · Kept ${counts.kept}',
            ),
          ),
        ),
      ],
    ),
  );
}

class DeviceAccountChanges extends StatelessWidget {
  const DeviceAccountChanges({super.key, required this.counts});
  final DeviceAccountCounts counts;
  @override
  Widget build(BuildContext context) => Text(
    context.l10n.select(
      zh: '账号：新增 ${counts.added} · 替换 ${counts.replaced} · 移除 ${counts.removed}',
      en: 'Accounts: Added ${counts.added} · Replaced ${counts.replaced} · Removed ${counts.removed}',
    ),
  );
}
