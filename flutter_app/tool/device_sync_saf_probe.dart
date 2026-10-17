// Standalone synthetic transport probe. No Rust initialization, accounts or library access.
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:squid_album/src/platform/device_sync_saf.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: _Probe()));
}

class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final saf = DeviceSyncSaf();
  final session = List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  String state = 'Select Documents/NSOAlbumSync';
  bool busy = false;
  void report(String message) {
    debugPrint('DEVICE_SYNC_SAF_PROBE session=$session $message');
    if (mounted) setState(() => state = message);
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
    } catch (error) {
      report('FAIL ${error.runtimeType} $error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> roundtrip() async {
    await saf.cancel();
    await saf.openSession(session, session);
    final bytes = Uint8List.fromList(List.generate(123, (i) => (i * 37) & 255));
    const name = '0000000000000000.block';
    await saf.writeCiphertextBlock(name, bytes);
    final names = await saf.listBlocks('mobile');
    final received = await saf.readBlock('mobile', name);
    if (names.length != 1 ||
        names.single != name ||
        received.length != bytes.length ||
        List.generate(
          bytes.length,
          (i) => received[i] == bytes[i],
        ).contains(false)) {
      throw StateError('Synthetic byte mismatch');
    }
    var duplicateRejected = false;
    try {
      await saf.writeCiphertextBlock(name, Uint8List.fromList([1]));
    } catch (_) {
      duplicateRejected = true;
    }
    if (!duplicateRejected) throw StateError('Overwrite accepted');
    await saf.cancel();
    report('PASS SAF write/read/duplicate/cancel 123 bytes');
  }

  Future<void> readDesktop() async {
    await saf.cancel();
    await saf.openSession(session, session);
    final bytes = await saf.readBlock('desktop', '0000000000000000.block');
    if (bytes.length != 123 ||
        List.generate(
          123,
          (i) => bytes[i] == ((i * 37) & 255),
        ).contains(false)) {
      throw StateError('Desktop synthetic byte mismatch');
    }
    await saf.cancel();
    report('PASS Windows MTP -> Android SAF 123 bytes');
  }

  @override
  void dispose() {
    unawaited(saf.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('SAF native probe')),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText('Session: $session\n$state'),
          TextButton(
            onPressed: busy
                ? null
                : () => run(() async {
                    await saf.selectTree();
                    report('Directory authorized');
                  }),
            child: const Text('Select exchange directory'),
          ),
          TextButton(
            onPressed: busy ? null : () => run(roundtrip),
            child: const Text('Synthetic SAF roundtrip'),
          ),
          TextButton(
            onPressed: busy ? null : () => run(readDesktop),
            child: const Text('Read desktop synthetic block'),
          ),
          TextButton(
            onPressed: busy
                ? null
                : () => run(() async {
                    await saf.revoke();
                    report('Authorization revoked');
                  }),
            child: const Text('Revoke directory authorization'),
          ),
        ],
      ),
    ),
  );
}
