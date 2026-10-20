@Tags(['platform-android'])
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:squid_album/src/l10n/app_localizations.dart';
import 'package:squid_album/src/state/settings_controller.dart';
import 'package:squid_album/src/state/sync_controller.dart';
import 'package:squid_album/src/state/transfer_controller.dart';
import 'package:squid_album/src/ui/android/android_nintendo_sync_page.dart';
import 'package:squid_album/src/ui/android/android_page_frame.dart';

import '../home_shell_test.dart' show FakeBackend;

const _failure =
    'provider failed: NXAPI /f failed (HTTP 400); NXAPI code: invalid_request';

class _FailedLoginBackend extends FakeBackend {
  _FailedLoginBackend() : super(signedIn: true, mediaItems: []);

  @override
  Future<void> completeNintendoLogin(String callbackUrl) async =>
      throw _failure;
}

Widget _localized(String locale, Widget home) => MaterialApp(
  locale: Locale(locale),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

void main() {
  for (final locale in ['zh', 'en']) {
    testWidgets(
      'second login string error is localized and remains actionable in $locale',
      (tester) async {
        tester.view.physicalSize = const Size(412, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final backend = _FailedLoginBackend();
        final settings = SettingsController(backend);
        final sync = SyncController(backend, allAccounts: true);
        final transfer = TransferController(backend, settings, sync);
        await transfer.refresh();
        await tester.pumpWidget(
          _localized(locale, AndroidNintendoSyncPage(controller: transfer)),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(locale == 'zh' ? '添加账号' : 'Add account'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.text(locale == 'zh' ? '打开登录页面' : 'Open sign-in page'),
        );
        await tester.tap(
          find.text(locale == 'zh' ? '打开登录页面' : 'Open sign-in page'),
        );
        await tester.pumpAndSettle();
        const callback = 'npf-test://auth?session_token_code=synthetic';
        await tester.enterText(find.byType(TextField).first, callback);
        final complete = find.text(
          locale == 'zh' ? '完成登录' : 'Complete sign-in',
        );
        await tester.ensureVisible(complete);
        await tester.tap(complete);
        await tester.pump();
        expect(find.byIcon(Icons.error_outline), findsOneWidget);
        expect(find.byIcon(Icons.check_circle_outline), findsNothing);
        expect(
          find.text(
            locale == 'zh' ? 'Nintendo 登录服务请求失败，请稍后重试。' : 'The Nintendo sign-in service request failed. Please try again later.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('provider failed'), findsNothing);
        expect(find.text(callback), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(
                  FilledButton,
                  locale == 'zh' ? '完成登录' : 'Complete sign-in',
                ),
              )
              .onPressed,
          isNotNull,
        );
        await tester.pump(const Duration(seconds: 3));
        expect(find.byKey(const Key('android-notice-bubble')), findsOneWidget);
        await tester.pump(const Duration(seconds: 5));
        expect(find.byKey(const Key('android-notice-bubble')), findsNothing);
        expect(transfer.accounts, hasLength(1));
        expect(sync.running, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        transfer.dispose();
        sync.dispose();
        settings.dispose();
      },
    );
  }

  testWidgets('explicit success notices retain their text and short duration', (
    tester,
  ) async {
    await tester.pumpWidget(
      _localized(
        'zh',
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => androidMessage(context, '已保存', isError: false),
              child: const Text('trigger'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('trigger'));
    await tester.pump();
    expect(find.text('已保存'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const Key('android-notice-bubble')), findsNothing);
  });

  testWidgets(
    'string failures copy a sanitized diagnostic rather than the summary',
    (tester) async {
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(
        _localized(
          'zh',
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => androidMessage(
                  context,
                  '$_failure\nsession_token=PRIVATE https://example.invalid/?secret=PRIVATE',
                ),
                child: const Text('trigger'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('trigger'));
      await tester.pump();
      final copy = find.byKey(const Key('android-notice-copy-diagnostic'));
      expect(copy, findsOneWidget);
      await tester.tap(copy);
      expect(copied, contains('NXAPI code: invalid_request'));
      expect(copied, isNot(contains('PRIVATE')));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
