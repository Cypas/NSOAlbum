import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../../backend/device_sync/account_gate.dart' show DeviceSyncBusy;
import '../../backend/device_sync/service_contract.dart';
import '../../l10n/app_localizations.dart';
import '../../platform/device_sync_network.dart';
import '../../rust/device_sync/driver.dart' as driver;
import '../../rust/device_sync/read_model.dart' as read;
import 'backup_page.dart';
import 'debug_pairing.dart';
import 'connection_info.dart';
import 'capacity_format.dart';
import 'display.dart';
import 'frame.dart';
import 'invitation_qr.dart';
import 'page_access.dart';
import 'scanner_page.dart';
import 'session_panel.dart';

class DeviceSyncPage extends StatefulWidget {
  const DeviceSyncPage({
    super.key,
    required this.access,
    required this.mobile,
    this.onLibraryChanged,
    this.cameraFactory = createDeviceQrCamera,
  });
  final DeviceSyncPageAccess access;
  final bool mobile;
  final Future<void> Function()? onLibraryChanged;
  final DeviceQrCamera Function() cameraFactory;
  @override
  State<DeviceSyncPage> createState() => _DeviceSyncPageState();
}

class _DeviceSyncPageState extends State<DeviceSyncPage>
    with WidgetsBindingObserver {
  late final _name = TextEditingController(
    text: widget.mobile ? 'Android' : 'Desktop',
  );
  DeviceSyncSessionController? _session;
  final _ownedSessions = <DeviceSyncSessionController>{};
  DeviceUsbAttemptController? _attempt;
  Future<void>? _action, _observation;
  Timer? _timer;
  List<DeviceLanAddress>? _addresses;
  DeviceLanAddress? _selectedAddress;
  DeviceWifiSnapshot _wifi = const DeviceWifiSnapshot();
  String? _peerSsid;
  bool _invitationInspected = false;
  List<DeviceUsbStorageChoice>? _storages;
  Object? _error;
  bool _usb = false, _leaving = false, _asking = false, _allowPop = false;
  bool _changed = false;
  bool _ownedSettled = false, _settledFailure = false;
  Object? _lateOpeningFailure;
  StackTrace? _lateOpeningStack;
  int _epoch = 0;
  DeviceSyncPairingDebugBinding? _debugPairing;
  Completer<bool>? _foregroundWait;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.access.addListener(_accessChanged);
    if (kDebugMode) {
      final bridge = DeviceSyncPairingDebug.instance;
      bridge.register();
      _debugPairing = bridge.bind(
        mobile: widget.mobile,
        active: _debugActive,
        transport: () => _usb ? 'usb' : 'wifi',
        canInject: _canDebugInject,
        readInvitation: _debugInvitation,
        inject: _injectDebugInvitation,
      );
    }
  }

  bool _debugActive() =>
      mounted &&
      !_leaving &&
      (!widget.mobile ||
          WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.resumed) &&
      ModalRoute.of(context)?.isCurrent == true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wait = _foregroundWait;
    if (wait == null || wait.isCompleted) return;
    if (state == AppLifecycleState.resumed) {
      wait.complete(true);
    } else if (state != AppLifecycleState.inactive) {
      wait.complete(false);
    }
  }

  void _stopForegroundWait() {
    final wait = _foregroundWait;
    if (wait != null && !wait.isCompleted) wait.complete(false);
  }

  void _checkPairingForeground(int epoch) {
    if (!mounted || _leaving || epoch != _epoch || !_debugActive()) {
      throw const DeviceSyncBusy();
    }
  }

  Future<void> _resumeAfterPermission(int epoch) async {
    // A permission dialog may briefly leave the activity inactive after the
    // channel returns. Never wait through Home, lock or a covered page.
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.inactive &&
        mounted &&
        !_leaving &&
        epoch == _epoch &&
        ModalRoute.of(context)?.isCurrent == true) {
      final wait = _foregroundWait = Completer<bool>();
      try {
        final resumed = await wait.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => false,
        );
        if (!resumed) throw const DeviceSyncBusy();
      } finally {
        if (identical(_foregroundWait, wait)) _foregroundWait = null;
      }
    }
    _checkPairingForeground(epoch);
  }

  bool _canDebugInject() =>
      _debugActive() &&
      widget.mobile &&
      widget.access.ready &&
      _session == null &&
      _action == null &&
      !_asking &&
      _name.text.trim().isNotEmpty;

  String? _debugInvitation() {
    final session = _session;
    final view = session?.snapshot?.value;
    if (widget.mobile ||
        session == null ||
        session.closed ||
        view == null ||
        view.terminal ||
        view.pairing != read.PairingStage.handshaking ||
        (view.invitationRemainingMs ?? BigInt.zero) <= BigInt.zero) {
      return null;
    }
    return session.invitation;
  }

  Future<void> _injectDebugInvitation(String invitation) async {
    if (!_canDebugInject()) throw const DeviceSyncBusy();
    var accepted = false;
    await _run((epoch) async {
      await _acceptInvitation(invitation, epoch);
      accepted = mounted && !_leaving && epoch == _epoch && _session != null;
    });
    if (!accepted) throw const DeviceSyncBusy();
  }

  void _accessChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function(int epoch) action) async {
    if (_action != null || _leaving) return;
    final done = Completer<void>();
    _action = done.future;
    final epoch = _epoch;
    setState(() => _error = null);
    try {
      await action(epoch);
    } catch (error, stack) {
      if (epoch != _epoch && _leaving && _ownedSessions.isEmpty) {
        // A known unexecuted cancellation owns no endpoint. Unknown late
        // opening/retirement failures are not evidence that it is safe to pop.
        if (error is! DeviceSyncBusy) {
          _lateOpeningFailure = error;
          _lateOpeningStack = stack;
        }
      }
      if (mounted && epoch == _epoch) setState(() => _error = error);
    } finally {
      done.complete();
      _action = null;
      if (mounted) setState(() {});
    }
  }

  Future<void> _attach(DeviceSyncSessionController session, int epoch) async {
    _ownedSessions.add(session);
    if (!mounted || epoch != _epoch || _leaving) {
      await session.close();
      return;
    }
    setState(() {
      _session = session;
      _changed = false;
    });
    await _observe(session);
  }

  Future<void> _observe(DeviceSyncSessionController session) {
    if (_observation case final current?) return current;
    final epoch = _epoch;
    late final Future<void> flight;
    flight = () async {
      try {
        final read = await session.refresh();
        if (!mounted ||
            _leaving ||
            epoch != _epoch ||
            !identical(_session, session)) {
          return;
        }
        final view = read.value;
        if (view?.source == false &&
            view?.cleanupPending == false &&
            (view?.stage == driver.State.completed ||
                view?.stage == driver.State.completedUnconfirmed) &&
            !_changed) {
          _changed = true;
          await widget.onLibraryChanged?.call();
        }
        if (mounted && epoch == _epoch) setState(() {});
      } catch (error) {
        if (mounted && epoch == _epoch && !_leaving) {
          setState(() => _error = error);
        }
      } finally {
        if (identical(_observation, flight)) _observation = null;
        if (mounted &&
            epoch == _epoch &&
            !_leaving &&
            !session.closed &&
            identical(_session, session) &&
            (session.snapshot?.value?.terminal != true ||
                session.snapshot?.value?.cleanupPending == true)) {
          _timer = Timer(const Duration(milliseconds: 500), () {
            unawaited(_observe(session));
          });
        }
      }
    }();
    _observation = flight;
    return flight;
  }

  Future<void> _host(int epoch) async {
    if (!_usb) {
      final wifi = await widget.access.wifiInfo();
      if (!mounted || _leaving || epoch != _epoch) throw const DeviceSyncBusy();
      setState(() => _wifi = wifi);
    }
    final session = await widget.access.host(
      usb: _usb,
      name: _name.text.trim(),
      address: _selectedAddress?.address,
      wifiSsid: _usb ? null : _wifi.ssidForAddress(_selectedAddress?.address),
    );
    await _attach(session, epoch);
  }

  Future<void> _scan(int epoch) async {
    final invitation = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) =>
            DeviceSyncScannerPage(cameraFactory: widget.cameraFactory),
      ),
    );
    if (invitation == null || !mounted || _leaving || epoch != _epoch) return;
    await _acceptInvitation(invitation, epoch);
  }

  Future<void> _acceptInvitation(String invitation, int epoch) async {
    if (!mounted || _leaving || epoch != _epoch || _session != null) {
      throw const DeviceSyncBusy();
    }
    final connection = await widget.access.inspectInvitation(invitation);
    _checkPairingForeground(epoch);
    setState(() {
      _usb = connection.usb;
      _peerSsid = connection.wifiSsid;
      _wifi = const DeviceWifiSnapshot();
      _invitationInspected = true;
    });
    if (!_usb) {
      final wifi = await widget.access.wifiInfo(requestPermission: true);
      await _resumeAfterPermission(epoch);
      setState(() => _wifi = wifi);
    }
    final DeviceSyncSessionController session;
    if (_usb) {
      final attempt = _attempt = widget.access.prepareUsb(
        invitation: invitation,
        name: _name.text.trim(),
      );
      if (mounted) setState(() {});
      session = await attempt.connect();
    } else {
      session = await widget.access.joinWifi(
        invitation: invitation,
        name: _name.text.trim(),
      );
    }
    await _attach(session, epoch);
  }

  Future<void> _stopOwned() async {
    _epoch++;
    _stopForegroundWait();
    _timer?.cancel();
    _timer = null;
    // Cancel a picker before waiting for the action which is awaiting it.
    Object? firstFailure;
    StackTrace? firstStack;
    Future<void> settle(Future<void> Function() operation) async {
      try {
        await operation();
      } catch (failure, stack) {
        if (firstFailure == null) {
          firstFailure = failure;
          firstStack = stack;
        }
      }
    }

    await settle(() async => _attempt?.cancel());
    await settle(() async => _action);
    if (_lateOpeningFailure != null && firstFailure == null) {
      firstFailure = _lateOpeningFailure;
      firstStack = _lateOpeningStack;
    }
    for (final session in _ownedSessions.toList()) {
      await settle(session.close);
    }
    await settle(() async => _observation);
    _ownedSettled =
        _action == null &&
        _observation == null &&
        _lateOpeningFailure == null &&
        _ownedSessions.every((session) => session.settled);
    if (firstFailure != null) {
      Error.throwWithStackTrace(firstFailure!, firstStack!);
    }
  }

  void _reset() => setState(() {
    _session = null;
    _ownedSessions.clear();
    _attempt = null;
    _storages = null;
    _error = null;
    _leaving = false;
    _settledFailure = false;
    _ownedSettled = false;
    _lateOpeningFailure = null;
    _lateOpeningStack = null;
    _selectedAddress = null;
    _addresses = null;
    _wifi = const DeviceWifiSnapshot();
    _peerSsid = null;
    _invitationInspected = false;
  });

  Future<void> _pop() async {
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  Future<bool> _confirmEnd() async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(
            context.l10n.select(zh: '结束本次连接？', en: 'End this connection?'),
          ),
          content: Text(
            context.l10n.select(
              zh: '将取消并等待当前操作安全结束。若已进入提交或补偿阶段，需要等待处理完成。再次连接需要新的二维码。',
              en: 'Cancel and wait for the current operation to finish safely. Commit or compensation may need time to settle. A new code is required to reconnect.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(
                context.l10n.select(zh: '继续连接', en: 'Keep connection'),
              ),
            ),
            FilledButton(
              key: const Key('device-confirm-leave'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.select(zh: '结束并等待', en: 'End and wait')),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _end({required bool leave}) async {
    if (_leaving || _asking) return;
    if (_settledFailure && _ownedSettled) {
      if (leave) {
        await _pop();
      } else {
        _reset();
      }
      return;
    }
    _asking = true;
    final active =
        _action != null ||
        (_session != null && _session!.snapshot?.value?.terminal != true);
    final confirmed = !active || await _confirmEnd();
    _asking = false;
    if (!confirmed || !mounted) return;
    setState(() => _leaving = true);
    try {
      await _stopOwned();
      if (!mounted) return;
      if (leave) {
        await _pop();
      } else {
        _reset();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _leaving = false;
          _settledFailure = _ownedSettled;
        });
      }
    }
  }

  Future<void> _backups(int _) async {
    final browser = widget.access.openBackups();
    if (!mounted || _leaving) {
      await browser.close();
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DeviceSyncBackupPage(
          browser: browser,
          mobile: widget.mobile,
          onLibraryChanged: widget.onLibraryChanged,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _debugPairing?.dispose();
    _stopForegroundWait();
    WidgetsBinding.instance.removeObserver(this);
    _epoch++;
    _timer?.cancel();
    widget.access.removeListener(_accessChanged);
    _name.dispose();
    // Fallback for forced route disposal; normal back awaits _stopOwned.
    unawaited(_attempt?.cancel().catchError((Object _) {}));
    for (final session in _ownedSessions) {
      unawaited(session.close().catchError((Object _) {}));
    }
    widget.access.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final busy = _action != null || _leaving;
    return DeviceSyncFrame(
      mobile: widget.mobile,
      title: context.l10n.select(zh: '设备同步', en: 'Device sync'),
      canPop: _allowPop,
      onBack: () => unawaited(_end(leave: true)),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_leaving)
            Text(
              context.l10n.select(
                zh: '正在等待操作安全结束…',
                en: 'Waiting for the operation to finish safely…',
              ),
            ),
          if (widget.access.ready && (!widget.mobile || _invitationInspected))
            DeviceSyncConnectionInfo(
              usb: _usb,
              mobile: widget.mobile,
              wifi: _wifi,
              selectedAddress: _selectedAddress?.address,
              peerSsid: _peerSsid,
            ),
          if (!widget.access.ready) ...[
            Text(
              context.l10n.select(
                zh: '设备同步暂不可用。图库数据仍受保护，请先完成数据恢复检查。',
                en: 'Device sync is unavailable. Library data remains protected. Complete the data recovery check first.',
              ),
            ),
            if (widget.access.canCheckRecovery)
              FilledButton(
                key: const Key('device-check-recovery'),
                onPressed: busy || widget.access.checking
                    ? null
                    : () => _run((_) => widget.access.checkRecovery()),
                child: Text(
                  context.l10n.select(zh: '检查并恢复', en: 'Check and restore'),
                ),
              ),
          ] else if (session == null) ...[
            Text(
              context.l10n.select(
                zh: '在电脑与 Android 之间同步图库。电脑生成一次性二维码后，由手机选择同步内容并确认授权，电脑可随时取消。手机扫码后自动使用对应连接；账号默认不传输。',
                en: 'Sync your library between desktop and Android. Creating a one-time code lets the phone choose and authorize this sync; the computer can cancel at any time. The phone uses the scanned connection automatically. Accounts are excluded by default.',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              enabled: !busy,
              maxLength: 32,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: context.l10n.select(
                  zh: '本机显示名',
                  en: 'This device’s display name',
                ),
              ),
            ),
            if (!widget.mobile) ...[
              Text(
                context.l10n.select(zh: '同步方式', en: 'Connection method'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                children: [
                  ChoiceChip(
                    key: const Key('device-wifi'),
                    label: const Text('Wi-Fi'),
                    selected: !_usb,
                    onSelected: busy
                        ? null
                        : (_) => setState(() => _usb = false),
                  ),
                  ChoiceChip(
                    key: const Key('device-usb'),
                    label: const Text('USB'),
                    selected: _usb,
                    onSelected: busy
                        ? null
                        : (_) => setState(() => _usb = true),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            if (widget.mobile) ...[
              Text(
                context.l10n.select(
                  zh: 'Wi-Fi 连接需在同一局域网；USB 连接需启用文件传输，并授权 Documents/NSOAlbumSync 专用交换目录。系统可能要求位置权限以读取 Wi-Fi 名称；不会读取定位坐标，拒绝仍可尝试连接。',
                  en: 'For Wi-Fi, use the same local network. For USB, enable file transfer and grant access to Documents/NSOAlbumSync. The system may request location permission to read the Wi-Fi name. Location coordinates are not read; declining still allows a connection attempt.',
                ),
              ),
              FilledButton.icon(
                key: const Key('device-scan-code'),
                onPressed: busy || _name.text.trim().isEmpty
                    ? null
                    : () => _run(_scan),
                icon: const Icon(Icons.qr_code_scanner),
                label: Text(
                  context.l10n.select(zh: '扫描桌面二维码', en: 'Scan desktop code'),
                ),
              ),
              if (_attempt != null && busy)
                Text(
                  context.l10n.select(
                    zh: '请在系统选择器中授权交换目录，可返回取消。',
                    en: 'Grant access to the exchange folder in the system picker, or go back to cancel.',
                  ),
                ),
            ] else ...[
              if (!_usb) ...[
                OutlinedButton.icon(
                  key: const Key('device-load-addresses'),
                  onPressed: busy
                      ? null
                      : () => _run((epoch) async {
                          final addresses = await widget.access.wifiAddresses();
                          final wifi = await widget.access.wifiInfo();
                          if (mounted && epoch == _epoch && !_leaving) {
                            setState(() {
                              _addresses = addresses;
                              _selectedAddress = null;
                              _wifi = wifi;
                            });
                          }
                        }),
                  icon: const Icon(Icons.network_check),
                  label: Text(
                    context.l10n.select(
                      zh: '查找本机局域网地址',
                      en: 'Find local network addresses',
                    ),
                  ),
                ),
                if (_addresses?.isEmpty == true)
                  Text(
                    context.l10n.select(
                      zh: '没有可用的活动私有 IPv4 地址。请检查网络连接。',
                      en: 'No active private IPv4 address is available. Check the network connection.',
                    ),
                  ),
                for (var i = 0; i < (_addresses?.length ?? 0); i++)
                  CheckboxListTile(
                    key: Key('device-address-$i'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: identical(_selectedAddress, _addresses![i]),
                    title: Text(_addresses![i].interfaceName),
                    subtitle: Text(_addresses![i].address),
                    onChanged: busy
                        ? null
                        : (_) =>
                              setState(() => _selectedAddress = _addresses![i]),
                  ),
              ] else
                Text(
                  context.l10n.select(
                    zh: '连接手机并启用普通 USB 文件传输。生成二维码后选择枚举到的手机存储；设备组件不可用时，请检查应用安装和连接。',
                    en: 'Connect the phone using ordinary USB file transfer. After creating a code, select its detected storage. If the device component is unavailable, check the app installation and connection.',
                  ),
                ),
              FilledButton.icon(
                key: const Key('device-create-code'),
                onPressed:
                    busy ||
                        (!_usb && _selectedAddress == null) ||
                        _name.text.trim().isEmpty
                    ? null
                    : () => _run(_host),
                icon: const Icon(Icons.qr_code_2),
                label: Text(
                  context.l10n.select(
                    zh: '生成一次性二维码',
                    en: 'Create one-time code',
                  ),
                ),
              ),
            ],
            const Divider(height: 32),
            OutlinedButton.icon(
              key: const Key('device-backups'),
              onPressed: busy ? null : () => _run(_backups),
              icon: const Icon(Icons.restore),
              label: Text(
                context.l10n.select(zh: '备份与恢复', en: 'Backups and restore'),
              ),
            ),
          ] else ...[
            if (session.invitation case final invitation?)
              DeviceInvitationQr(
                invitation: invitation,
                remainingMs: session.snapshot?.value?.invitationRemainingMs,
              ),
            if (_usb &&
                !widget.mobile &&
                session.snapshot?.value?.terminal != true) ...[
              OutlinedButton(
                key: const Key('device-find-usb'),
                onPressed: busy || session.busy
                    ? null
                    : () => _run((epoch) async {
                        final storages = await session.usbChoices();
                        if (mounted && epoch == _epoch && !_leaving) {
                          setState(() => _storages = storages);
                        }
                      }),
                child: Text(
                  context.l10n.select(zh: '查找手机存储', en: 'Find phone storage'),
                ),
              ),
              if (_storages?.isEmpty == true)
                Text(
                  context.l10n.select(
                    zh: '未发现可用存储。设备组件可能不可用，或手机尚未授权文件传输。',
                    en: 'No storage is available. The device component may be unavailable, or the phone may not have allowed file transfer.',
                  ),
                ),
              for (final choice in _storages ?? <DeviceUsbStorageChoice>[])
                OutlinedButton(
                  onPressed: busy || session.busy
                      ? null
                      : () => _run((_) async {
                          await session.selectUsb(choice);
                          if (mounted) setState(() => _storages = null);
                        }),
                  child: Text(
                    '${choice.deviceName}\n${choice.storageName}\n${context.l10n.select(zh: '可用空间', en: 'Available space')}: ${formatDeviceCapacity(choice.freeBytes)}',
                  ),
                ),
            ],
            DeviceSyncSessionPanel(key: ObjectKey(session), session: session),
            const SizedBox(height: 16),
            OutlinedButton(
              key: Key(
                session.snapshot?.value?.terminal == true || session.closed
                    ? 'device-new-pairing'
                    : 'device-end-session',
              ),
              onPressed: _leaving ? null : () => _end(leave: false),
              child: Text(
                session.snapshot?.value?.terminal == true || session.closed
                    ? context.l10n.select(zh: '重新配对', en: 'Pair again')
                    : context.l10n.select(
                        zh: '取消并结束连接',
                        en: 'Cancel and end connection',
                      ),
              ),
            ),
          ],
          if (_error case final error?)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                deviceSyncError(context, error),
                key: const Key('device-page-error'),
              ),
            ),
          if (_settledFailure && _ownedSettled)
            OutlinedButton(
              key: const Key('device-return-after-error'),
              onPressed: () => _end(leave: true),
              child: Text(context.l10n.select(zh: '返回', en: 'Return')),
            ),
        ],
      ),
    );
  }
}
