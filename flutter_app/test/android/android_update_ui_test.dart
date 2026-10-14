import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/release_update.dart';
import 'package:squid_album/src/state/android_update_controller.dart';
import 'package:squid_album/src/ui/android/android_update_dialog.dart';
import 'package:squid_album/src/ui/android/android_update_controls.dart';

import '../android_release_update_test.dart' show metadata;

Widget app(Widget child, String language) => MaterialApp(
  locale: Locale(language),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: Scaffold(body: child),
);

void main() {
  for (final language in ['zh', 'en']) {
    testWidgets('$language update confirmation exposes later ignore download', (
      tester,
    ) async {
      AndroidUpdateAction? result;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showAndroidReleaseUpdateDialog(
                  context,
                  release: latestReleaseInfoFromGithubJson(
                    metadata(),
                    '0.2.14',
                  )!,
                );
              },
              child: const Text('Open'),
            ),
          ),
          language,
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text(language == 'en' ? 'Later' : '稍后'), findsOneWidget);
      expect(
        find.text(language == 'en' ? 'Ignore this version' : '忽略此版本'),
        findsOneWidget,
      );
      expect(
        find.text(language == 'en' ? 'Download update' : '下载更新'),
        findsOneWidget,
      );
      expect(find.textContaining('0.3.0'), findsOneWidget);
      await tester.tap(find.byKey(const Key('android-update-download')));
      await tester.pumpAndSettle();
      expect(result, AndroidUpdateAction.download);
    });

    testWidgets('$language missing APK is visible and cannot download', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                showAndroidReleaseUpdateDialog(
                  context,
                  release: latestReleaseInfoFromGithubJson(
                    metadata()..['assets'] = [],
                    '0.2.14',
                  )!,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
          language,
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          language == 'en'
              ? 'No verified Android package'
              : '没有可验证的 Android 安装包',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('android-update-download')), findsNothing);
      await tester.tap(find.byKey(const Key('android-update-later')));
      await tester.pumpAndSettle();
    });

    testWidgets(
      '$language restored ready package has an in-app install action',
      (tester) async {
        const channel = MethodChannel('io.github.cypas.nsoalbum/update');
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              return call.method == 'install'
                  ? null
                  : {
                      'state': 'ready',
                      'version': '0.3.0',
                      'received': 1024,
                      'total': 1024,
                      'error': null,
                      'notificationAllowed': false,
                    };
            });
        final controller = AndroidUpdateController();
        addTearDown(() async {
          controller.dispose();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });
        await controller.restore();
        await tester.pumpWidget(
          app(AndroidUpdateControls(controller: controller), language),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(language == 'en' ? 'Install new version' : '安装新版本'),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('android-install-update')));
        await tester.pumpAndSettle();
        expect(calls.where((call) => call.method == 'install'), hasLength(1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
