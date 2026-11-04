import 'package:flutter/material.dart';

import '../../backend/device_sync/service_contract.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/device_sync/driver.dart' as driver;
import '../../rust/device_sync/read_model.dart' as read;
import '../../rust/device_sync/work.dart' show PreparationStage;
import 'capacity_format.dart';
import 'display.dart';

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
        preparationPhase: current.preparationPhase,
        workActive: current.workActive,
        scannedItems: current.scannedItems,
        totalItems: current.totalItems,
        comparedItems: current.comparedItems,
        totalComparedItems: current.totalComparedItems,
        processedItems: current.processedItems,
        currentItem: current.currentItem,
        processedBytes: current.processedBytes,
        totalBytes: current.totalBytes,
        transferredBytes:
            current.transferredBytes ??
            (retainTransfer ? _progress?.transferredBytes : null),
        transferTotalBytes:
            current.transferTotalBytes ??
            (retainTransfer ? _progress?.transferTotalBytes : null),
        transferBytesPerSecond: current.transferBytesPerSecond,
        ratePerSecond: current.ratePerSecond,
        etaMs: current.etaMs,
        isEstimate: current.isEstimate,
        applyPhase: current.applyPhase,
        applyPublicationBytes: current.applyPublicationBytes,
        applySqlSteps: current.applySqlSteps,
        applyAccountSteps: current.applyAccountSteps,
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
    final view = widget.session.snapshot?.value;
    final receivingVerification =
        stage == driver.State.verifying &&
        view?.source == false &&
        progress.totalBytes != null;
    double? ratio(BigInt value, BigInt? total) =>
        total != null && total > BigInt.zero
        ? (value.toDouble() / total.toDouble()).clamp(0.0, .999)
        : null;
    final transferEtaMs =
        progress.transferredBytes == null ||
            progress.transferTotalBytes == null ||
            progress.transferBytesPerSecond == null
        ? null
        : estimateDeviceSyncRemainingMs(
            processedBytes: progress.transferredBytes!,
            totalBytes: progress.transferTotalBytes!,
            bytesPerSecond: progress.transferBytesPerSecond!,
          );
    final comparing = stage == driver.State.comparing;
    final preparationPhase = deviceSyncActivePreparation(stage, progress);
    final preparing = preparationPhase != null;
    final stalePreparation = progress.preparationPhase != null && !preparing;
    final processedItems = preparing
        ? progress.processedItems
        : comparing
        ? (progress.comparedItems ?? progress.scannedItems)
        : progress.scannedItems;
    final totalItems = preparing
        ? progress.totalItems
        : comparing
        ? (progress.totalComparedItems ?? progress.totalItems)
        : progress.totalItems;
    final stageEtaMs = stalePreparation
        ? (stage == driver.State.transferring ? transferEtaMs : null)
        : progress.etaMs ?? transferEtaMs;
    final itemRate = progress.ratePerSecond;
    final applySqlSteps = progress.applySqlSteps;
    final applyAccountSteps = progress.applyAccountSteps;
    final applyProgressStage =
        stage == driver.State.applying ||
        stage == driver.State.awaitingExternal;
    final applyingWithWork = applyProgressStage && progress.applyPhase != null;
    final applyingWithoutDetails =
        applyProgressStage && progress.workActive && !applyingWithWork;
    final isEnglish = context.l10n.select(zh: 'zh', en: 'en') == 'en';
    final etaText = formatDeviceSyncEta(
      stageEtaMs == null || (preparing && stageEtaMs <= BigInt.zero)
          ? null
          : Duration(milliseconds: stageEtaMs.toInt()),
      unknown: context.l10n.select(zh: '正在估算', en: 'Estimating'),
      english: isEnglish,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (applyingWithWork) ...[
          const SizedBox(height: 12),
          Semantics(
            key: const Key('device-apply-progress'),
            liveRegion: true,
            label: _applyPhaseLabel(context, progress.applyPhase!),
            child: ExcludeSemantics(
              child: LinearProgressIndicator(
                key: const Key('device-apply-progress-bar'),
              ),
            ),
          ),
          Text(
            _applyPhaseLabel(context, progress.applyPhase!),
            key: const Key('device-apply-phase'),
          ),
          if (progress.applyPublicationBytes case final bytes?)
            Text(
              context.l10n.select(
                zh: '已发布媒体数据 ${formatDeviceCapacity(bytes)}',
                en: 'Published media data ${formatDeviceCapacity(bytes)}',
              ),
              key: const Key('device-apply-publication-bytes'),
            ),
          if (progress.applyPhase == read.ApplyProgressPhase.sql &&
              applySqlSteps != null)
            Text(
              context.l10n.select(
                zh: '数据库工作单元 $applySqlSteps',
                en: 'Database work units $applySqlSteps',
              ),
              key: const Key('device-apply-sql-steps'),
            ),
          if (progress.applyPhase == read.ApplyProgressPhase.accounts &&
              applyAccountSteps != null)
            Text(
              context.l10n.select(
                zh: '已完成账号步骤 $applyAccountSteps',
                en: 'Account steps completed $applyAccountSteps',
              ),
              key: const Key('device-apply-account-steps'),
            ),
          Text(
            context.l10n.select(zh: '预计剩余：$etaText', en: 'Remaining: $etaText'),
            key: const Key('device-apply-eta'),
          ),
        ],
        if (receivingVerification) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(
            key: const Key('device-verify-byte-progress'),
            value: ratio(
              progress.processedBytes ?? BigInt.zero,
              progress.totalBytes,
            ),
          ),
          Text(
            context.l10n.select(
              zh: '已校验 ${formatDeviceCapacity(progress.processedBytes ?? BigInt.zero)} / ${formatDeviceCapacity(progress.totalBytes)} · 文件 ${progress.processedItems ?? BigInt.zero} / ${progress.totalItems ?? '…'}',
              en: 'Verified ${formatDeviceCapacity(progress.processedBytes ?? BigInt.zero)} / ${formatDeviceCapacity(progress.totalBytes)} · Files ${progress.processedItems ?? BigInt.zero} / ${progress.totalItems ?? '…'}',
            ),
            key: const Key('device-verify-byte-count'),
          ),
          if (_safeVerificationItem(progress.currentItem))
            Text(
              context.l10n.select(
                zh: '正在校验文件 ${progress.currentItem}',
                en: 'Verifying file ${progress.currentItem}',
              ),
              key: const Key('device-verify-current-item'),
            ),
          Text(
            context.l10n.select(zh: '预计剩余：$etaText', en: 'Remaining: $etaText'),
            key: const Key('device-verify-eta'),
          ),
        ],
        // Native checkpoints must not insert another bar during transfer.
        if (stage != driver.State.transferring &&
            !applyProgressStage &&
            !stalePreparation &&
            (progress.workActive || preparing) &&
            !receivingVerification) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(
            key: const Key('device-item-progress'),
            value: ratio(processedItems ?? BigInt.zero, totalItems),
          ),
          if (processedItems != null)
            Text(
              context.l10n.select(
                zh: '已处理项目 $processedItems / ${totalItems ?? '…'}',
                en: 'Items processed $processedItems / ${totalItems ?? '…'}',
              ),
              key: const Key('device-item-count'),
            ),
          if (!preparing &&
              (stage == driver.State.scanning ||
                  stage == driver.State.comparing) &&
              totalItems == null)
            Text(
              context.l10n.select(
                zh: stage == driver.State.scanning ? '正在统计图库项目' : '正在统计待比较项目',
                en: stage == driver.State.scanning
                    ? 'Counting library items'
                    : 'Counting items to compare',
              ),
              key: const Key('device-stage-counting'),
            ),
          if ((stage == driver.State.scanning ||
                  stage == driver.State.comparing ||
                  preparing) &&
              _safeVerificationItem(progress.currentItem))
            Text(
              context.l10n.select(
                zh: preparationPhase == PreparationStage.checkingCache
                    ? '当前检查项 ${_spacedOrdinal(progress.currentItem!)}'
                    : stage == driver.State.scanning
                    ? '当前扫描项 ${_spacedOrdinal(progress.currentItem!)}'
                    : '当前比较项 ${_spacedOrdinal(progress.currentItem!)}',
                en: preparationPhase == PreparationStage.checkingCache
                    ? 'Checking item ${_spacedOrdinal(progress.currentItem!)}'
                    : stage == driver.State.scanning
                    ? 'Scanning item ${_spacedOrdinal(progress.currentItem!)}'
                    : 'Comparing item ${_spacedOrdinal(progress.currentItem!)}',
              ),
              key: const Key('device-stage-current-item'),
            ),
          if ((stage == driver.State.scanning ||
                  stage == driver.State.comparing ||
                  preparing) &&
              (!preparing || processedItems != null) &&
              itemRate != null &&
              itemRate > BigInt.zero)
            Text(
              context.l10n.select(
                zh: '平均处理速度：$itemRate 项/秒',
                en: 'Average processing speed: $itemRate items/s',
              ),
              key: const Key('device-item-rate'),
            ),
          if (preparing
              ? processedItems != null &&
                    totalItems != null &&
                    processedItems < totalItems
              : totalItems != null ||
                    stage == driver.State.scanning ||
                    stage == driver.State.comparing)
            Text(
              context.l10n.select(
                zh: '预计剩余：$etaText',
                en: 'Remaining: $etaText',
              ),
              key: const Key('device-stage-eta'),
            ),
        ],
        if (stage != driver.State.transferring &&
            !preparing &&
            (!progress.workActive ||
                applyingWithoutDetails ||
                stalePreparation) &&
            !receivingVerification &&
            !applyingWithWork &&
            deviceSyncStageShowsProgress(stage)) ...[
          const SizedBox(height: 12),
          Semantics(
            key: const Key('device-stage-progress'),
            label: deviceSyncStageProgressLabel(context, stage),
            liveRegion: true,
            child: ExcludeSemantics(
              child: LinearProgressIndicator(
                key: const Key('device-stage-progress-bar'),
              ),
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
          Text(
            context.l10n.select(zh: '预计剩余：$etaText', en: 'Remaining: $etaText'),
            key: const Key('device-transfer-eta'),
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

  bool _safeVerificationItem(String? value) {
    if (value == null) return false;
    final parts = value.split('/');
    if (parts.length != 2) return false;
    final current = int.tryParse(parts[0]);
    final total = int.tryParse(parts[1]);
    return current != null &&
        total != null &&
        current > 0 &&
        total > 0 &&
        current <= total;
  }

  String _spacedOrdinal(String value) {
    final parts = value.split('/');
    if (parts.length != 2) return value;
    return '${parts[0]} / ${parts[1]}';
  }

  String _applyPhaseLabel(BuildContext context, read.ApplyProgressPhase phase) {
    final (zh, en) = switch (phase) {
      read.ApplyProgressPhase.preparing => (
        '正在准备图库变更',
        'Preparing library changes',
      ),
      read.ApplyProgressPhase.publishing => (
        '正在发布媒体数据',
        'Publishing media data',
      ),
      read.ApplyProgressPhase.sql => ('正在更新图库数据', 'Updating library data'),
      read.ApplyProgressPhase.finalizing => (
        '正在完成图库事务',
        'Finalizing library changes',
      ),
      read.ApplyProgressPhase.accounts => (
        '正在安全保存账号',
        'Saving accounts securely',
      ),
    };
    return context.l10n.select(zh: zh, en: en);
  }
}
