import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../l10n/app_localizations.dart';
import 'frame.dart';

abstract interface class DeviceQrCamera {
  Future<void> start();
  Future<void> stop();
  Future<void> dispose();
  Widget preview({
    required ValueChanged<String> onCode,
    required VoidCallback onFailure,
  });
}

enum DeviceCameraFailure implements Exception { permissionDenied, unavailable }

DeviceQrCamera createDeviceQrCamera() {
  if (!Platform.isAndroid) throw DeviceCameraFailure.unavailable;
  return _MobileQrCamera();
}

final class _MobileQrCamera implements DeviceQrCamera {
  final _controller = MobileScannerController(
    autoStart: false,
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
    returnImage: false,
  );
  @override
  Future<void> start() async {
    try {
      await _controller.start();
      if (_controller.value.error case final error?) {
        throw error;
      }
      if (!_controller.value.isRunning) throw DeviceCameraFailure.unavailable;
    } on MobileScannerException catch (error) {
      throw error.errorCode == MobileScannerErrorCode.permissionDenied
          ? DeviceCameraFailure.permissionDenied
          : DeviceCameraFailure.unavailable;
    }
  }

  @override
  Future<void> stop() => _controller.stop();
  @override
  Future<void> dispose() => _controller.dispose();
  @override
  Widget preview({
    required ValueChanged<String> onCode,
    required VoidCallback onFailure,
  }) => ExcludeSemantics(
    child: MobileScanner(
      controller: _controller,
      useAppLifecycleState: false,
      onDetect: (capture) {
        for (final barcode in capture.barcodes) {
          if (barcode.rawValue case final value?) {
            onCode(value);
            break;
          }
        }
      },
      onDetectError: (_, _) => onFailure(),
      errorBuilder: (_, _) =>
          const Center(child: Icon(Icons.no_photography_outlined)),
    ),
  );
}

/// Owns only this page's camera; no protocol/session is created until it exits.
class DeviceSyncScannerPage extends StatefulWidget {
  const DeviceSyncScannerPage({
    super.key,
    this.cameraFactory = createDeviceQrCamera,
  });
  final DeviceQrCamera Function() cameraFactory;
  @override
  State<DeviceSyncScannerPage> createState() => _DeviceSyncScannerPageState();
}

class _CameraLease {
  _CameraLease(this.camera);
  final DeviceQrCamera camera;
  Future<void>? starting, _closing;
  bool _startSettled = false;
  Future<void> start() =>
      starting ??= camera.start().whenComplete(() => _startSettled = true);
  Future<void> close() => _closing ??= () async {
    final pendingStart = starting != null && !_startSettled;
    Object? firstFailure;
    StackTrace? firstStack;
    try {
      try {
        // A pending native start may acquire the camera after this stop.
        await camera.stop();
      } catch (error, stack) {
        firstFailure = error;
        firstStack = stack;
      }
      try {
        await starting;
      } catch (_) {
        // The enable caller owns the original start failure.
      }
      if (pendingStart) await camera.stop();
    } finally {
      await camera.dispose();
    }
    if (firstFailure != null) {
      Error.throwWithStackTrace(firstFailure, firstStack!);
    }
  }();
}

class _DeviceSyncScannerPageState extends State<DeviceSyncScannerPage>
    with WidgetsBindingObserver {
  _CameraLease? _lease;
  Future<void>? _settling;
  DeviceCameraFailure? _failure;
  bool _enabling = false,
      _accepted = false,
      _leaving = false,
      _allowPop = false;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _enable() async {
    if (_lease != null ||
        _enabling ||
        _settling != null ||
        _accepted ||
        _leaving) {
      return;
    }
    final epoch = ++_epoch;
    setState(() {
      _enabling = true;
      _failure = null;
    });
    _CameraLease? lease;
    try {
      lease = _CameraLease(widget.cameraFactory());
      setState(() => _lease = lease);
      // Insert the plugin widget before start requests permission.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || epoch != _epoch) return;
      await lease.start();
    } catch (error) {
      if (mounted && epoch == _epoch) {
        _failure = error is DeviceCameraFailure
            ? error
            : DeviceCameraFailure.unavailable;
        await _release();
      }
    } finally {
      if (mounted) setState(() => _enabling = false);
    }
  }

  Future<void> _release() {
    if (_settling case final current?) return current;
    _epoch++;
    final lease = _lease;
    _lease = null;
    if (mounted) setState(() {});
    late final Future<void> flight;
    flight = () async {
      try {
        await lease?.close();
      } finally {
        if (identical(_settling, flight)) {
          _settling = null;
          if (mounted) setState(() {});
        }
      }
    }();
    _settling = flight;
    return flight;
  }

  Future<void> _accept(String invitation, int epoch) async {
    if (invitation.isEmpty ||
        _accepted ||
        _leaving ||
        epoch != _epoch ||
        _lease == null) {
      return;
    }
    _accepted = true;
    await _finish(invitation);
  }

  Future<void> _finish([String? invitation]) async {
    if (_leaving) return;
    _leaving = true;
    try {
      await _release();
      if (!mounted) return;
      setState(() => _allowPop = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop(invitation);
    } catch (_) {
      if (mounted) {
        setState(() {
          _failure = DeviceCameraFailure.unavailable;
          _leaving = false;
          _accepted = false;
        });
      }
    }
  }

  Future<void> _pause() async {
    try {
      await _release();
    } catch (_) {
      if (mounted) setState(() => _failure = DeviceCameraFailure.unavailable);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_pause());
    // Never automatically restart on resume. The enable button is required.
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _epoch++;
    final lease = _lease;
    _lease = null;
    unawaited(lease?.close().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lease = _lease;
    final epoch = _epoch;
    return DeviceSyncFrame(
      mobile: true,
      title: context.l10n.select(zh: '扫描桌面二维码', en: 'Scan desktop code'),
      onBack: () => unawaited(_finish()),
      canPop: _allowPop,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            context.l10n.select(
              zh: '在桌面打开设备同步并选择相同连接方式。启用相机后，将二维码放入取景框。二维码只用于本次连接，不会保存。',
              en: 'Open Device sync on the desktop and choose the same connection method. Enable the camera and place its code in the viewfinder. The code is used only for this connection and is not saved.',
            ),
          ),
          const SizedBox(height: 16),
          if (lease != null)
            AspectRatio(
              aspectRatio: 1,
              child: lease.camera.preview(
                onCode: (value) => unawaited(_accept(value, epoch)),
                onFailure: () {
                  if (epoch == _epoch && !_leaving) {
                    _failure = DeviceCameraFailure.unavailable;
                    unawaited(_pause());
                  }
                },
              ),
            ),
          if (_failure case final failure?)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                failure == DeviceCameraFailure.permissionDenied
                    ? context.l10n.select(
                        zh: '相机访问被拒绝。可重试授权，或在系统设置中允许相机；图库仍可正常使用。',
                        en: 'Camera access was denied. Retry, or allow camera access in system settings. Your library is still available.',
                      )
                    : context.l10n.select(
                        zh: '相机当前不可用。请检查相机权限和占用情况后重试。',
                        en: 'The camera is unavailable. Check camera access and whether another app is using it, then retry.',
                      ),
              ),
            ),
          if (_enabling || _settling != null)
            Text(
              context.l10n.select(
                zh: '正在等待相机安全结束…',
                en: 'Waiting for the camera to settle safely…',
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('device-enable-camera'),
            onPressed:
                lease != null || _enabling || _settling != null || _leaving
                ? null
                : _enable,
            icon: const Icon(Icons.qr_code_scanner),
            label: Text(context.l10n.select(zh: '启用相机扫码', en: 'Enable camera')),
          ),
        ],
      ),
    );
  }
}
