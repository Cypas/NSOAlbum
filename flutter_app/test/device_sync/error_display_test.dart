import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/backend/device_sync/service_contract.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/rust/device_sync/read_model.dart' as read;
import 'package:squid_album/src/ui/device_sync/display.dart';

void main() {
  for (final language in ['zh', 'en']) {
    testWidgets(
      'incompatible transport profile explains updating both devices in $language',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Builder(
              builder: (context) => Text(
                deviceSyncError(
                  context,
                  const DeviceSyncReadFailure(read.ReadError.versionMismatch),
                ),
              ),
            ),
          ),
        );
        expect(
          find.textContaining(language == 'zh' ? '传输协议' : 'transfer protocol'),
          findsOneWidget,
        );
        expect(
          find.textContaining(language == 'zh' ? '更新' : 'Update both'),
          findsOneWidget,
        );
      },
    );
  }
  testWidgets(
    'an invalid transfer block is not reported as an invalid QR code',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Builder(
            builder: (context) => Text(
              deviceSyncError(
                context,
                const DeviceSyncReadFailure(read.ReadError.invalidInput),
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('二维码'), findsNothing);
      expect(find.textContaining('校验'), findsOneWidget);
    },
  );
  for (final language in ['zh', 'en']) {
    testWidgets(
      'apply failure explains verified files can be reused in $language',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Builder(
              builder: (context) => Text(
                deviceSyncError(
                  context,
                  const DeviceSyncReadFailure(read.ReadError.applyFailed),
                ),
              ),
            ),
          ),
        );
        expect(
          find.textContaining(
            language == 'zh' ? '已校验的暂存文件' : 'Verified staged files',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            language == 'zh'
                ? '匹配的缓存可复用而不重传'
                : 'matching cached files can be reused without retransferring',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('SHA-256'), findsNothing);
      },
    );
  }
  testWidgets(
    'invalid invitations name QR validation while transfer corruption does not',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Builder(
            builder: (context) =>
                Text(deviceSyncError(context, const DeviceInvitationFailure())),
          ),
        ),
      );
      expect(find.textContaining('QR code is invalid'), findsOneWidget);
    },
  );
  for (final language in ['zh', 'en']) {
    testWidgets(
      'USB timeout explains unlocking the phone and file transfer in $language',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: Builder(
              builder: (context) => Text(
                deviceSyncError(
                  context,
                  const DeviceSyncReadFailure(read.ReadError.timeout),
                ),
              ),
            ),
          ),
        );
        expect(
          find.textContaining(language == 'zh' ? '解锁手机' : 'unlock the phone'),
          findsOneWidget,
        );
        expect(
          find.textContaining(language == 'zh' ? '文件传输' : 'file transfer'),
          findsOneWidget,
        );
      },
    );
  }
}
