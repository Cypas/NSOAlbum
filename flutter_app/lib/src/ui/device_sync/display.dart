import 'package:flutter/material.dart';

import '../../backend/device_sync/account_coordinator.dart'
    show AccountPreviewChanged, AccountRecoveryRequired;
import '../../backend/device_sync/account_gate.dart' show DeviceSyncBusy;
import '../../backend/device_sync/account_storage.dart'
    show AccountConsentRequired;
import '../../backend/device_sync/service_contract.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/device_sync/driver.dart' as driver;
import '../../rust/device_sync/read_model.dart' as read;
import '../../rust/device_sync/runtime.dart' show DeviceCommandError;

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
    read.ReadError.disconnected || read.ReadError.timeout => (
      '连接已断开或超时。请检查同一局域网、网络隔离、防火墙或 USB 连接，然后重新扫码。',
      'The connection was lost or timed out. Check the same local network, network isolation, firewall, or USB connection, then scan a new code.',
    ),
    read.ReadError.cancelled => ('操作已取消。', 'Operation cancelled.'),
    read.ReadError.invalidInput => (
      '二维码或连接信息无效。请在桌面生成新的二维码。',
      'The code or connection information is invalid. Generate a new code on the desktop.',
    ),
    read.ReadError.versionMismatch => (
      '两端软件版本号或构建号不一致，或二维码缺少版本信息。请将两端更新至相同版本和构建后，重新生成二维码。',
      'The app version or build number differs, or this code has no version information. Update both devices to the same version and build, then generate a new code.',
    ),
    _ when error is AccountConsentRequired => (
      '读取账号变化前需要单独授权。',
      'Separate consent is required before reading account changes.',
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

class DeviceChangeCounts extends StatelessWidget {
  const DeviceChangeCounts({
    super.key,
    required this.title,
    required this.counts,
  });
  final String title;
  final read.ChangeCounts counts;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(
      context.l10n.select(
        zh: '$title：新增 ${counts.added} · 替换 ${counts.replaced} · 移出 ${counts.removed} · 保留 ${counts.kept}',
        en: '$title: Added ${counts.added} · Replaced ${counts.replaced} · Removed ${counts.removed} · Kept ${counts.kept}',
      ),
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
