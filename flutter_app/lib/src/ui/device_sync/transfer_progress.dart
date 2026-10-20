import 'package:flutter/material.dart';

import '../../backend/device_sync/service_contract.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/device_sync/driver.dart' as driver;
import '../../rust/device_sync/read_model.dart' as read;
import 'capacity_format.dart';

/// Keeps transfer counters independent of the session controls and preview.
class DeviceSyncTransferProgress extends StatefulWidget {
  const DeviceSyncTransferProgress({super.key, required this.session});
  final DeviceSyncSessionController session;

  @override
  State<DeviceSyncTransferProgress> createState() =>
      _DeviceSyncTransferProgressState();
}

class _DeviceSyncTransferProgressState
    extends State<DeviceSyncTransferProgress> {
  read.ProgressView? _progress;
  driver.State? _stage;
  bool _preserveTransferredBytes = false;

  @override
  void initState() {
    super.initState();
    _capture();
    widget.session.addListener(_sessionChanged);
  }

  @override
  void didUpdateWidget(covariant DeviceSyncTransferProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      oldWidget.session.removeListener(_sessionChanged);
      _progress = null;
      _stage = null;
      _capture();
      widget.session.addListener(_sessionChanged);
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_sessionChanged);
    super.dispose();
  }

  void _capture() {
    final view = widget.session.snapshot?.value;
    final current = widget.session.presentationProgress ?? view?.progress;
    final retainTransfer =
        view?.stage == driver.State.transferring &&
        _stage == driver.State.transferring;
    if (current != null) {
      // Work/read samples may omit byte counters. Retain known bytes only in
      // this transfer phase. Independent Rust counters publish idle zero;
      // missing initial speed is zero, never an indefinitely stale rate.
      _progress = read.ProgressView(
        workStage: current.workStage,
        workActive: current.workActive,
        scannedItems: current.scannedItems,
        totalItems: current.totalItems,
        transferredBytes:
            current.transferredBytes ??
            (retainTransfer ? _progress?.transferredBytes : null),
        transferTotalBytes:
            current.transferTotalBytes ??
            (retainTransfer ? _progress?.transferTotalBytes : null),
        transferBytesPerSecond: current.transferBytesPerSecond,
      );
    } else {
      _progress = null;
    }
    _stage = view?.stage;
    _preserveTransferredBytes =
        view?.localApplyInstalled == true &&
        view?.source == false &&
        view?.transportDetached == true &&
        view?.terminal == false;
  }

  void _sessionChanged() {
    final before = _visibleSample;
    _capture();
    final after = _visibleSample;
    if (mounted && before != after) setState(() {});
  }

  Object get _visibleSample => (
    _stage,
    _preserveTransferredBytes,
    _stage == driver.State.transferring
        ? (
            _progress?.transferredBytes,
            _progress?.transferTotalBytes,
            _progress?.transferBytesPerSecond,
          )
        : _progress,
  );

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    final stage = _stage;
    if (progress == null || stage == null) return const SizedBox.shrink();
    double? ratio(BigInt value, BigInt? total) =>
        total != null && total > BigInt.zero
        ? (value.toDouble() / total.toDouble()).clamp(0.0, .999)
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Native checkpoints must not insert another bar during transfer.
        if (stage != driver.State.transferring && progress.workActive) ...[
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
        if (stage == driver.State.transferring) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(
            key: const Key('device-byte-progress'),
            value: progress.transferredBytes == null
                ? null
                : ratio(
                    progress.transferredBytes!,
                    progress.transferTotalBytes,
                  ),
          ),
          Text(
            context.l10n.select(
              zh: '已传输 ${formatDeviceCapacity(progress.transferredBytes, unknown: '未知')} / ${formatDeviceCapacity(progress.transferTotalBytes, unknown: '未知')}',
              en: 'Transferred ${formatDeviceCapacity(progress.transferredBytes, unknown: 'Unknown')} / ${formatDeviceCapacity(progress.transferTotalBytes, unknown: 'Unknown')}',
            ),
          ),
          Text(
            context.l10n.select(
              zh: '当前速度：${formatDeviceTransferRate(progress.transferBytesPerSecond ?? BigInt.zero)}',
              en: 'Current speed: ${formatDeviceTransferRate(progress.transferBytesPerSecond ?? BigInt.zero)}',
            ),
            key: const Key('device-transfer-rate'),
          ),
        ],
        if (_preserveTransferredBytes &&
            stage != driver.State.transferring &&
            progress.transferredBytes != null)
          Text(
            context.l10n.select(
              zh: '已传输 ${formatDeviceCapacity(progress.transferredBytes)} / ${formatDeviceCapacity(progress.transferTotalBytes, unknown: '未知')}',
              en: 'Transferred ${formatDeviceCapacity(progress.transferredBytes)} / ${formatDeviceCapacity(progress.transferTotalBytes, unknown: 'Unknown')}',
            ),
          ),
      ],
    );
  }
}
