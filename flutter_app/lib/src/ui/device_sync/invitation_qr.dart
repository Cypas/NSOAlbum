import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/app_localizations.dart';

class DeviceInvitationQr extends StatelessWidget {
  const DeviceInvitationQr({
    super.key,
    required this.invitation,
    this.remainingMs,
  });
  final String invitation;
  final BigInt? remainingMs;
  @override
  Widget build(BuildContext context) {
    final seconds = remainingMs == null
        ? null
        : ((remainingMs! + BigInt.from(999)) ~/ BigInt.from(1000)).toInt();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.l10n.select(
            zh: '请用 Android 扫描。二维码仅供本次连接，五分钟后失效。',
            en: 'Scan with Android. This one-time connection code expires after five minutes.',
          ),
        ),
        const SizedBox(height: 12),
        if (seconds == null || seconds > 0)
          LayoutBuilder(
            builder: (context, constraints) => Center(
              child: Semantics(
                image: true,
                label: context.l10n.select(
                  zh: '一次性设备配对二维码',
                  en: 'One-time device pairing code',
                ),
                child: ExcludeSemantics(
                  child: QrImageView(
                    data: invitation,
                    size: constraints.maxWidth.clamp(0, 360),
                    backgroundColor: Colors.white,
                    padding: const EdgeInsets.all(20),
                    version: QrVersions.auto,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                    semanticsLabel: '',
                  ),
                ),
              ),
            ),
          ),
        if (seconds != null)
          Text(
            seconds <= 0
                ? context.l10n.select(
                    zh: '二维码已失效，请重新配对。',
                    en: 'The code expired. Pair again for a new code.',
                  )
                : context.l10n.select(
                    zh: '剩余 ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
                    en: 'Expires in ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
                  ),
          ),
        const SizedBox(height: 12),
      ],
    );
  }
}
